# アーキテクチャ詳細

## システム概要

IaC Drift Detective は、TerraformによってプロビジョニングされたAWSリソースと実際の状態との乖離（ドリフト）を自動検知し、Amazon Bedrockを用いてその原因を分析・修復HCLを生成してGitHub PRを自動作成するサーバーレスシステムです。

インフラエンジニアの手動作業なしに「ドリフト検知 → 原因分析 → 修復コード提案」のサイクルを実現します。

## コンポーネント詳細

### EventBridge（スケジューラー）

| 項目 | 詳細 |
|---|---|
| ルール名 | `drift-detective-schedule` |
| スケジュール | `cron(0 0 * * ? *)` （毎日 09:00 JST） |
| ターゲット | Step Functions ステートマシン |
| 認証 | IAMロール（Step Functions起動権限のみ） |

### Step Functions（オーケストレーター）

| 項目 | 詳細 |
|---|---|
| ステートマシン名 | `DriftDetectionWorkflow` |
| タイプ | Standard（実行履歴の長期保持が必要なため） |
| 定義 | `step_functions/drift_workflow.asl.json` |

**ステート遷移:**

```
DetectDrift
  → (差分なし) → NoDriftFound [成功終了]
  → (差分あり) → AnalyzeDrift
      → (バリデーション成功) → CreatePR [成功終了]
      → (バリデーション失敗) → ValidationFailed [TaskFailed]
      → (Bedrock呼び出し失敗) → AnalysisFailed [TaskFailed]
```

---

### Lambda: drift-detector

**責務:** S3上のtfstateとAWS CloudFormation Drift Detection APIを使って実環境との差分リストを生成する。

**入力（EventBridgeから）:**
```json
{}
```

**出力:**
```json
{
  "has_drift": true,
  "drift_count": 3,
  "drifted_resources": [
    {
      "resource_type": "AWS::EC2::SecurityGroup",
      "logical_id": "WebServerSG",
      "physical_id": "sg-0123456789abcdef0",
      "drift_status": "MODIFIED",
      "property_differences": [...]
    }
  ],
  "tfstate_bucket": "my-tfstate-bucket",
  "tfstate_key": "terraform.tfstate"
}
```

**主要モジュール:**

| ファイル | 役割 |
|---|---|
| `index.py` | Lambdaハンドラー。Lambda Powertoolsデコレータ適用 |
| `drift_scanner.py` | CloudFormation Drift Detection API呼び出し・ポーリング |
| `state_comparator.py` | S3からtfstateを取得し、差分リストを生成 |

**IAM権限（最小権限）:**
- `cloudformation:DetectStackDrift`
- `cloudformation:DescribeStackDriftDetectionStatus`
- `cloudformation:DescribeStackResourceDrifts`
- `s3:GetObject`（監視対象tfstateバケットのみ）

---

### Lambda: bedrock-analyzer

**責務:** drift-detectorの差分データを受け取り、Bedrockで原因分析と修復HCL生成を行い、バリデーション後にS3へ保存する。

**入力（Step Functionsから）:**
```json
{
  "drifted_resources": [...],
  "tfstate_bucket": "...",
  "tfstate_key": "..."
}
```

**出力（バリデーション済み）:**
```json
{
  "drift_summary": "SecurityGroupのインバウンドルールが手動変更されています",
  "root_cause": "コンソールからの直接変更によりTerraform管理外のルールが追加された",
  "remediation_hcl": "resource \"aws_security_group_rule\" \"...\"{...}",
  "severity": "HIGH",
  "affected_resources": ["sg-0123456789abcdef0"],
  "report_s3_key": "reports/2026-04-26/analysis-abc123.json"
}
```

**AI出力バリデーション（5項目）:**

1. `drift_summary` フィールドが存在し、文字列であること
2. `root_cause` フィールドが存在すること
3. `remediation_hcl` フィールドが存在し、`resource` キーワードを含むこと
4. `severity` が `HIGH` / `MEDIUM` / `LOW` のいずれかであること
5. `affected_resources` がリスト形式であること

バリデーション失敗時はStep FunctionsのTaskFailedとして処理し、PR作成をスキップします。

**主要モジュール:**

| ファイル | 役割 |
|---|---|
| `index.py` | Lambdaハンドラー・バリデーション制御 |
| `analyzer.py` | Bedrock invoke_model呼び出し・レスポンスパース |
| `prompt_builder.py` | 差分データからBedrockプロンプトを構築 |

**IAM権限（最小権限）:**
- `bedrock:InvokeModel`（Claude Sonnet 3.5モデルのみ、us-east-1）
- `s3:PutObject`（レポート保存バケットのみ）
- `ssm:GetParameter`（`/drift-detective/*`のみ）

---

### Lambda: pr-creator

**責務:** bedrock-analyzerの分析結果を受け取り、GitHub APIでブランチ・コミット・PRを作成し、Chatworkへ通知する。

**入力（Step Functionsから）:**
```json
{
  "drift_summary": "...",
  "remediation_hcl": "resource \"...\"",
  "severity": "HIGH",
  "affected_resources": [...],
  "report_s3_key": "..."
}
```

**GitHub PR構成:**
- ブランチ名: `drift-fix/YYYY-MM-DD-{severity}-{hash8}`
- PRタイトル: `[{severity}] ドリフト修復: {drift_summary(先頭60文字)}`
- PR本文: 影響リソース・原因説明・修復手順・重要度バッジ

**主要モジュール:**

| ファイル | 役割 |
|---|---|
| `index.py` | Lambdaハンドラー・処理フロー制御 |
| `github_client.py` | GitHub REST API操作（ブランチ/コミット/PR） |
| `hcl_formatter.py` | 生成HCLの整形・ファイルパス決定 |

**IAM権限（最小権限）:**
- `ssm:GetParameter`（`/drift-detective/github-token`, `/drift-detective/chatwork-token`）
- `s3:GetObject`（レポートバケットのみ）

---

## データフロー

```
1. EventBridge
   └─ cron(0 0 * * ? *) でStep Functionsを起動

2. drift-detector Lambda
   ├─ S3 (tfstateバケット) から terraform.tfstate を取得
   ├─ CloudFormation Drift Detection API を起動
   ├─ API完了までポーリング（最大10分）
   └─ 差分リストを生成してStep Functionsへ返却

3. bedrock-analyzer Lambda（差分あり時のみ）
   ├─ 差分データからプロンプトを構築
   ├─ Bedrock Claude Sonnet 3.5 (us-east-1) を呼び出し
   ├─ レスポンスをパース・バリデーション
   ├─ 分析結果をS3（レポートバケット）に保存
   └─ 構造化JSONをStep Functionsへ返却

4. pr-creator Lambda
   ├─ SSMからGitHub Token・Chatwork Tokenを取得
   ├─ GitHub APIでmainブランチから修復用ブランチを作成
   ├─ 修復HCLをファイルとしてコミット
   ├─ PR作成（分析結果を本文に記載）
   └─ Chatwork APIで通知（重要度・PR URL付き）
```

## エラーハンドリング設計

| レイヤー | エラー種別 | 対応 |
|---|---|---|
| drift-detector | CloudFormation API タイムアウト | Lambdaタイムアウト（15分）後にStep FunctionsがTaskFailed |
| drift-detector | tfstate取得失敗 | 例外をそのままraiseしてTaskFailed |
| bedrock-analyzer | Bedrock呼び出し失敗 | TaskFailed（リトライなし。コスト増加を防ぐため） |
| bedrock-analyzer | バリデーション失敗 | 専用のValidationFailedステートへ遷移 |
| pr-creator | GitHub API認証エラー | TaskFailed（SSMトークンの有効期限切れを疑う） |
| pr-creator | PR重複作成 | 同日同重要度のブランチ存在チェックでスキップ |

Step FunctionsのTaskFailed時はCloudWatch Alarmで検知し、運用担当者へ通知します（設定は運用者が別途行う）。

## セキュリティ設計

### 最小権限の原則

各Lambdaの実行ロールは、そのLambdaが必要とするリソース・アクションのみに限定しています。

- ワイルドカード（`*`）付きのIAM Actionは禁止
- リソースARNを明示的に指定（バケット名・パラメータパスなど）
- Lambda間の直接呼び出し権限は持たせない（Step Functions経由のみ）

### Secrets管理

GitHub TokenとChatwork TokenはSSM Parameter Store（SecureString）に格納します。

- 環境変数への直書き禁止
- Lambda実行時にSSMから取得（IAMロールで制御）
- `aws:kms`デフォルトキーによる暗号化

### CI/CD認証

GitHub ActionsからAWSへの接続はOIDCのみ使用します。

- AWSアクセスキーのGitHub Secrets保存禁止
- IAMロールの信頼ポリシーにリポジトリ名・ブランチを明示（`repo:owner/repo:ref:refs/heads/main`）
- 実行時に一時認証情報を発行（有効期間1時間）

### AI出力バリデーション

Bedrockの出力を信頼せず、5項目のスキーマバリデーションを実施します。不正な出力がそのままGitHubにコミットされることを防ぎます。

## スケーラビリティ考慮

### 現状（ポートフォリオ用途）

- 毎日1回の定期実行のみ
- 単一のTerraformステートファイルを対象

### 拡張ポイント

| 拡張内容 | 変更箇所 |
|---|---|
| 複数ステートファイルの並列監視 | Step FunctionsにMap状態を追加 |
| 実行頻度の変更 | EventBridgeルールのcron式を変更 |
| Slackへの通知追加 | pr-creator LambdaにSlack Webhook追加 |
| 重要度フィルタリング | Step FunctionsにChoice状態を追加 |
| Bedrockモデルの変更 | bedrock_analyzerモジュールの`model_id`変数を変更 |
