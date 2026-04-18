# CLAUDE.md - iam-least-privilege-advisor

## プロジェクト概要

AWS IAM Access Analyzer の未使用アクセス検出結果をトリガーに、
Lambda + Amazon Bedrock（Claude Sonnet）が既存の IAM ポリシーを最小権限版に書き直し、
Terraform 形式の GitHub PR を自動作成するシステム。
エンジニアは PR をレビューしてマージするだけで IAM 最小権限化を継続できる。

## ゴール

- IAM 過剰権限の検出〜修正提案を完全自動化する
- AI 生成ポリシーを人間がレビューする安全な GitOps フローを実現する
- Lambda 実行ロールに `iam:PutPolicy` 系権限を一切付与しない（PRマージまでポリシーは変わらない）
- すべてのインフラを Terraform で管理し、GitHub Actions（OIDC）で自動デプロイする

---

## ディレクトリ構成

以下の構成でファイルを生成すること。

```
iam-least-privilege-advisor/
├── terraform/
│   ├── modules/
│   │   ├── access_analyzer/
│   │   │   ├── main.tf          # Access Analyzer リソース（外部アクセス + 未使用アクセス）
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── eventbridge/
│   │   │   ├── main.tf          # Scheduler（毎週月曜 09:00 JST）
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── lambda/
│   │   │   ├── main.tf          # 2 Functions: analyzer-trigger / policy-advisor
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── s3/
│   │   │   ├── main.tf          # Analyzer 結果保存バケット
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── iam/
│   │       ├── main.tf          # 各 Lambda 実行ロール・ポリシー
│   │       ├── variables.tf
│   │       └── outputs.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── lambda/
│   ├── analyzer_trigger/
│   │   ├── handler.py           # Access Analyzer スキャン実行・結果収集
│   │   └── requirements.txt
│   └── policy_advisor/
│       ├── handler.py           # メインエントリーポイント
│       ├── bedrock_client.py    # Bedrock 呼び出しラッパー
│       ├── iam_fetcher.py       # 現行 IAM ポリシー取得
│       ├── terraform_formatter.py  # JSON → Terraform HCL 変換
│       ├── github_pr_creator.py    # GitHub API で PR 作成
│       ├── chatwork_notifier.py    # Chatwork 通知
│       └── requirements.txt
├── .github/
│   └── workflows/
│       └── deploy.yml
├── .gitignore
├── CLAUDE.md                    # このファイル
└── README.md
```

---

## 技術スタック・制約

| 項目 | 値 |
|------|-----|
| AWS リージョン | ap-northeast-1（東京）|
| Terraform バージョン | ~> 1.7 |
| Python バージョン | 3.12 |
| Bedrock モデル | anthropic.claude-sonnet-4-5 |
| 通知先 | Chatwork（Slack ではない）|
| 認証方式 | GitHub Actions OIDC（アクセスキー不使用）|
| Lambda アーキテクチャ | arm64（Graviton / コスト削減）|
| Lambda メモリ | analyzer-trigger: 256MB / policy-advisor: 512MB |
| Lambda タイムアウト | analyzer-trigger: 60秒 / policy-advisor: 120秒 |
| スケジュール実行 | 毎週月曜 00:00 UTC（= 09:00 JST）|

---

## Terraform 実装規約

### 命名規則
- リソース名: `{project_name}-{role}` 例: `iam-least-privilege-advisor-analyzer-trigger`
- モジュール名: スネークケース
- 変数名: スネークケース

### 共通タグ
```hcl
tags = {
  Project     = var.project_name
  Environment = var.environment
  ManagedBy   = "terraform"
}
```

### IAM ポリシー設計（最小権限・絶対遵守）

**analyzer-trigger Lambda 実行ロール**
- `access-analyzer:StartResourceScan`
- `access-analyzer:ListAnalyzers`
- `access-analyzer:ListFindings`（未使用アクセス analyzer のみ）
- `s3:PutObject`（結果保存バケット ARN/* のみ）
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

**policy-advisor Lambda 実行ロール**
- `s3:GetObject`（結果保存バケット ARN/* のみ）
- `iam:GetPolicy`, `iam:GetPolicyVersion`, `iam:ListPolicyVersions`（対象ポリシー ARN のみ）
- `bedrock:InvokeModel`（Sonnet モデルの ARN のみ）
- `secretsmanager:GetSecretValue`（GitHub Token / Chatwork Token の ARN のみ）
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`

**絶対禁止**:
- `iam:PutUserPolicy`, `iam:PutRolePolicy`, `iam:CreatePolicyVersion`（ポリシー変更系は一切不可）
- `*` ワイルドカード
- `AdministratorAccess`

### Secrets Manager
GitHub Token と Chatwork Token はそれぞれ別の Secrets Manager シークレットで管理する。
```hcl
variable "github_token_secret_arn" {
  description = "GitHub Personal Access Token の Secrets Manager ARN"
  type        = string
  sensitive   = true
}

variable "chatwork_secret_arn" {
  description = "Chatwork Token の Secrets Manager ARN"
  type        = string
  sensitive   = true
}
```

---

## Lambda 実装規約

### コメント規約
- 関数・クラスには docstring を必ず記載する
- AWS API 呼び出し箇所には使用する IAM アクションをコメントで明記する
- AI 出力の検証箇所には「# AI出力検証:」プレフィックスでコメントを記載する

### エラーハンドリング
- Bedrock 呼び出しは `ThrottlingException` を考慮し、指数バックオフ（1秒→2秒→4秒、最大3回）でリトライ
- GitHub API 失敗は `raise` して Lambda エラーとして記録する（PR 未作成のまま終了させない）
- Chatwork 通知失敗はログ記録のみ（処理を止めない）
- IAM ポリシー取得失敗は対象ロールをスキップしてログ出力（他のロールの処理は継続）

---

## analyzer-trigger Lambda 仕様

### handler.py の処理フロー

```
1. Access Analyzer の一覧取得（ListAnalyzers）
   - type: ACCOUNT_UNUSED_ACCESS のアナライザーを特定する
2. スキャン実行（StartResourceScan）
   - スキャン完了まで最大 30 秒ポーリング（5秒間隔）
3. 未使用アクセスの Findings 取得（ListFindings）
   - フィルタ: status = ACTIVE
   - 取得対象: ロール・ユーザーの未使用アクション（unusedActions）
4. 結果を S3 に保存
   - キー: analyzer-results/{YYYY}/{MM}/{DD}/findings.json
5. policy-advisor Lambda を非同期で起動（boto3 Lambda invoke, InvocationType=Event）
```

### S3 保存フォーマット
```json
{
  "scan_date": "2025-08-04T09:00:00+09:00",
  "analyzer_arn": "arn:aws:access-analyzer:ap-northeast-1:...",
  "findings": [
    {
      "finding_id": "...",
      "resource_arn": "arn:aws:iam::...:role/example-role",
      "resource_type": "AWS::IAM::Role",
      "unused_actions": ["s3:DeleteObject", "ec2:TerminateInstances"],
      "last_accessed": "2025-06-01T00:00:00Z"
    }
  ],
  "total_count": 5
}
```

---

## policy-advisor Lambda 仕様

### handler.py の処理フロー

```
1. S3 から analyzer-trigger の結果 JSON を取得
   - イベントに S3 キーが含まれる場合はそれを使用
   - 含まれない場合は当日の最新ファイルを取得
2. findings をロール単位でグループ化
3. 各ロールに対して処理：
   a. IamFetcher で現行のマネージドポリシーを取得
   b. BedrockClient で最小権限ポリシーを生成
   c. AI 出力検証（後述）
   d. TerraformFormatter で HCL に変換
   e. GithubPrCreator で PR を作成
   f. ChatworkNotifier で PR リンクを通知
4. 処理件数・PR 作成数をログ出力して返す
```

---

## Bedrock プロンプト設計

### システムプロンプト
```
あなたはAWS IAMセキュリティの専門家です。
現行のIAMポリシーと未使用アクションのリストを受け取り、最小権限の原則に従って
ポリシーを修正してください。

以下のJSONフォーマットのみで回答してください。説明文やMarkdownは不要です。

{
  "revised_policy": { /* 修正後のIAMポリシードキュメント（JSON）*/ },
  "removed_actions": ["削除したアクション一覧"],
  "reason": "変更理由の説明（日本語3〜5文）",
  "warnings": ["注意事項があれば記載（なければ空配列）"]
}

修正ルール:
1. unused_actions に含まれるアクションのみを削除する
2. Statement の構造・Condition・Resource 指定は変更しない
3. Effect: Allow の Statement のみ対象とする（Deny は変更しない）
4. 削除後にポリシーが空になる場合は removed_actions に全アクションを列挙し、
   warnings に「ポリシーが空になります。削除を検討してください」を追加する
```

### ユーザープロンプトに含める情報
- ロール ARN
- 現行ポリシー JSON（全文）
- 未使用アクション一覧（unused_actions）
- 最終アクセス日（last_accessed）

---

## AI 出力検証（重要）

`policy-advisor/handler.py` の AI 出力検証箇所に以下のチェックを実装すること。
検証失敗時は PR を作成せず、警告ログを出力して次のロールに進む。

```python
def validate_ai_policy(original_policy: dict, revised_policy: dict, unused_actions: list) -> tuple[bool, str]:
    """
    AI が生成したポリシーを検証する。

    検証項目:
    1. revised_policy が有効な IAM ポリシー構造か（Version, Statement が存在するか）
    2. unused_actions 以外のアクションが削除されていないか
    3. Resource 指定が元のポリシーから変更されていないか
    4. Condition が元のポリシーから変更・削除されていないか
    5. Effect: Deny の Statement が変更されていないか

    Returns:
        (is_valid: bool, error_message: str)
    """
```

---

## TerraformFormatter 仕様

`terraform_formatter.py` に以下を実装する：

```python
def format_as_terraform(policy_name: str, policy_arn: str, revised_policy: dict, reason: str, removed_actions: list) -> str:
    """
    IAM ポリシー JSON を Terraform aws_iam_policy リソースに変換する。

    出力形式:
    # AI生成 - レビュー必須
    # 削除されたアクション: s3:DeleteObject, ec2:TerminateInstances
    # 変更理由: ...
    resource "aws_iam_policy" "example" {
      name   = "example-policy"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [...]
      })
    }
    """
```

変換ルール：
- HCL の `jsonencode()` 形式を使用する（ヒアドキュメント不可）
- ファイル先頭に `# AI生成 - レビュー必須` コメントを必ず追加する
- 削除されたアクションと変更理由をコメントで記載する
- インデントはスペース 2 つ

---

## GithubPrCreator 仕様

`github_pr_creator.py` に以下を実装する：

### PR 作成フロー
```
1. Secrets Manager から GitHub Token 取得
2. デフォルトブランチの最新 SHA を取得（GET /repos/{owner}/{repo}/git/ref/heads/main）
3. 新規ブランチ作成: fix/iam-least-privilege-{YYYYMMDD}-{role_name_short}
4. ファイルをコミット: terraform/iam_policies/{role_name}.tf
5. PR 作成
```

### PR タイトル・本文フォーマット
```
タイトル: [IAM] {role_name} の最小権限化 ({YYYY/MM/DD})

本文:
## 概要
Amazon Bedrock (Claude Sonnet) による IAM ポリシー最小権限化の提案です。
**このPRは自動生成です。マージ前に必ずレビューしてください。**

## 対象ロール
`{role_arn}`

## 変更内容
### 削除されたアクション ({count}件)
{removed_actions を箇条書き}

### 変更理由
{reason}

{warnings があれば ⚠️ 警告セクションを追加}

## レビューチェックリスト
- [ ] 削除されたアクションが実際に不要であることを確認した
- [ ] Conditionが変更されていないことを確認した
- [ ] Resourceの指定が変更されていないことを確認した
- [ ] アプリケーションの動作に影響しないことを確認した

## 生成情報
- 生成日時: {JST}
- 使用モデル: anthropic.claude-sonnet-4-5
- Access Analyzer スキャン日: {scan_date}
```

---

## Chatwork 通知フォーマット

PR 作成成功時のみ通知する。

```
[info][title]🔐 IAM 最小権限 PR 作成完了[/title]
■ 対象ロール: {role_name}
■ 削除アクション数: {count}件
■ PR リンク: {pr_url}
■ 生成日時: {JST}
⚠️ マージ前に必ずレビューしてください
[/info]
```

---

## S3 バケット設計

- バケット名: `{project_name}-results-{account_id}`
- バージョニング: 有効
- パブリックアクセス: すべてブロック
- サーバーサイド暗号化: SSE-S3（AES256）
- ライフサイクルルール: 90日後に自動削除（Analyzer 結果は古くなるため）

---

## EventBridge Scheduler 設計

```hcl
# cron(0 0 ? * MON *) = 毎週月曜 00:00 UTC = 09:00 JST
schedule_expression = "cron(0 0 ? * MON *)"
flexible_time_window = { mode = "OFF" }
```

Scheduler のターゲットは `analyzer-trigger` Lambda のみ。
`policy-advisor` は `analyzer-trigger` から非同期で起動する（Lambda → Lambda 呼び出し）。

---

## 実装時の注意事項

1. **Bedrock モデル ID**: `anthropic.claude-sonnet-4-5` を使用する（IAMポリシー生成は精度重視）
2. **JSON パース**: Bedrock レスポンスの Markdown コードブロック（` ```json ` / ` ``` `）を除去してから `json.loads()` する
3. **IAM ポリシーの取得**: マネージドポリシーのみ対象とする（インラインポリシーは複雑なため今回は対象外）
4. **Access Analyzer のタイプ**: `ACCOUNT_UNUSED_ACCESS` を使用する（外部公開検出の `ACCOUNT` とは別）
5. **GitHub API の認証**: `Authorization: Bearer {token}` ヘッダーを使用する
6. **ブランチ名の長さ**: ロール名が長い場合は 20 文字に切り詰める
7. **タイムゾーン**: 通知・ログの日時はすべて JST で表示する
8. **Lambda → Lambda 呼び出し**: `policy-advisor` の Lambda ARN を `analyzer-trigger` の環境変数で渡す