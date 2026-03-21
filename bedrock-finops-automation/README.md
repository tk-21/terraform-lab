# bedrock-finops-automation

AWS Cost Explorer と Amazon Bedrock（Claude Haiku）を使って、月次コストレポートを自動生成・Chatwork 通知する FinOps 自動化基盤。

```
コスト収集 → 異常検知 → AI レポート生成 → Chatwork 通知
```

---

## アーキテクチャ

### 全体フロー

```
EventBridge（毎月1日 09:00 JST）
  │
  ▼
Step Functions ステートマシン
  │
  ├──▶ collector         Cost Explorer API でコストデータ収集 → S3 / DynamoDB
  ├──▶ anomaly-detector  前月比・スパイク・サービス集中度を検知 → S3
  ├──▶ ai-reporter       Bedrock（Claude Haiku）で AI 所見生成 → S3
  ├──▶ html-formatter    HTML レポート整形 → S3 保存
  └──▶ chatwork-notifier 要約 + 署名付き S3 リンクを Chatwork に通知
```

### Step Functions ステート間のデータフロー

各ステートは前のステートの返り値をそのまま受け取り、情報を追加して次に渡す。
大きな生データは S3 に保存し、Step Functions には S3 キーとサマリーのみを流す（256KB 制限対策）。

```
EventBridge
  │ 初期入力: {"source": "eventbridge-scheduler"}
  ▼
CollectCostData
  │ 出力: {report_id, current_month:{total_cost, top_services, s3_key}, prev_month:...}
  ▼
DetectAnomalies
  │ 出力: (上記) + {anomalies:[...], anomaly_summary:{count, has_high_severity}}
  ▼
GenerateAIReport
  │ 出力: (上記) + {ai_report:{summary, highlights, recommendations, risk_level}}
  ▼
FormatHTMLReport
  │ 出力: (上記) + {html_report:{s3_key, presigned_url}}
  ▼
SendChatworkNotification
  │ 出力: {report_id, report_date, status:"completed", chatwork_message_id}
  ▼
WorkflowSucceeded
```

エラー発生時はいずれのステートからも `WorkflowFailed`（Fail ステート）に遷移する。
各ステートにリトライ（最大 2 回・指数バックオフ）を設定済み。

### レポートに含まれる内容

1. 月次コスト合計・前月比較
2. サービス別コスト内訳（上位 10 件）
3. 異常検知・スパイクアラート
4. Bedrock による AI 所見・改善提案

### Chatwork 通知メッセージのイメージ

```
┌─────────────────────────────────────────────────────┐
│ AWS FinOps 月次コストレポート 2025-01                │
│                                                     │
│ ■ コスト概要                                        │
│   当月合計: $123.45                                 │
│   前月合計: $100.00                                 │
│   前月比:   +23.5%（上昇）                          │
│                                                     │
│ ■ 異常検知（2件）                                   │
│   [要対応] HIGH: 1件                                │
│   [注意] MEDIUM: 1件                                │
│   ■ 前月比 23.5% のコスト増加を検知                 │
│                                                     │
│ ■ AI 所見（リスクレベル: HIGH）                     │
│   EC2 と RDS のコストが急増しており...              │
└─────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────┐
│ 詳細レポート（7日間有効）                           │
│ https://s3.ap-northeast-1.amazonaws.com/...         │
└─────────────────────────────────────────────────────┘
```

---

## 技術スタック

| 項目 | 採用技術 |
|---|---|
| IaC | Terraform（モジュール化） |
| クラウド | AWS ap-northeast-1（Cost Explorer は us-east-1 固定） |
| 認証 | OIDC（アクセスキー不使用） |
| CI/CD | GitHub Actions |
| Lambda 言語 | Python 3.12 |
| AI モデル | claude-3-haiku（コスト最適化） |
| ワークフロー | Step Functions Standard Workflow |
| 通知先 | Chatwork |

---

## ディレクトリ構成

```
bedrock-finops-automation/
├── .github/
│   └── workflows/
│       ├── terraform.yml          OIDC 認証 + plan on PR / apply on main
│       └── integration-test.yml   手動 E2E テスト（Step Functions 実行確認）
├── bootstrap/                     OIDC IAM ロール（初回のみ手動 apply）
├── environments/
│   └── dev/
│       ├── backend.tf             S3 リモートステート
│       ├── versions.tf            プロバイダーバージョン・default_tags
│       ├── variables.tf
│       ├── outputs.tf
│       ├── main.tf                全モジュール呼び出し
│       └── terraform.tfvars
└── modules/
    ├── storage/                   S3（レポート保存）+ DynamoDB（履歴管理）
    ├── collector/                 Cost Explorer API でコスト収集
    ├── anomaly-detector/          前月比・集中度・新規サービスの異常検知
    ├── ai-reporter/               Bedrock（Claude Haiku）で AI 所見生成
    ├── html-formatter/            HTML レポート整形・S3 保存・署名付き URL 生成
    ├── chatwork-notifier/         Chatwork API 通知
    ├── workflow/                  Step Functions ステートマシン
    └── scheduler/                 EventBridge 月次スケジュール
```

---

## 月次ランニングコスト

**合計: 約 $0.42 / 月（≒ 60 円 / 月）**

月 1 回のバッチ実行のみのため、ほぼゼロコストで運用できる。

| サービス | 用途 | 月額 |
|---|---|---|
| **Secrets Manager** | Chatwork API トークン 1 件保管 | **$0.40** |
| Cost Explorer API | コストデータ取得（2 回/月） | $0.02 |
| Lambda | 5 関数 × 月 1 回 × 各 ~30 秒 | $0.00（無料枠） |
| Step Functions | 月 1 回実行（5 ステート） | $0.00（無料枠: 4,000 回/月） |
| S3 | JSON + HTML レポート（数 KB/月） | $0.00（無料枠） |
| DynamoDB | 月 1 回書き込み | $0.00（無料枠） |
| EventBridge | 月 1 回スケジュール実行 | $0.00（無料枠） |
| CloudWatch Logs | Lambda + Step Functions ログ 30 日保持 | $0.00（無料枠） |
| Bedrock（Haiku） | AI レポート生成 1 回/月（~2,000 tokens） | $0.00（$0.001 未満） |

> **コスト削減 TIP**: Secrets Manager の $0.40/月 を節約したい場合は SSM Parameter Store の SecureString（無料）に変更できる。

### S3 ライフサイクル

| 経過日数 | 動作 |
|---|---|
| 0〜90 日 | S3 Standard（通常アクセス） |
| 90 日〜 | S3 Glacier に自動移行（コスト約 1/10） |
| 365 日〜 | 自動削除 |

非カレントバージョン（上書きされた旧バージョン）は 30 日で削除。

---

## セットアップ

### 前提条件

- Terraform >= 1.5.0
- AWS CLI（設定済み）
- AWS アカウント（IAM 権限: PowerUserAccess + IAMFullAccess 以上）

### ステップ 1: GitHub Actions OIDC ロールの作成（初回のみ）

アクセスキーを使わず OIDC で GitHub Actions を認証するための IAM ロールを作成する。
**この手順は初回のみ**。以降は GitHub Actions が自動的にロールを引き受ける。

```bash
cd bootstrap/
terraform init
terraform apply -var="github_owner=YOUR_GITHUB_USERNAME"

# 出力された ARN を GitHub Secrets に登録する
# Settings > Secrets and variables > Actions > New repository secret
#   Name:  AWS_ROLE_ARN
#   Value: (terraform output の github_actions_role_arn)
```

### ステップ 2: Terraform バックエンド用リソースの作成

`terraform init` より先にバックエンド用の S3・DynamoDB を手動作成する。

```bash
aws s3 mb s3://tfstate-bedrock-finops-automation --region ap-northeast-1

aws dynamodb create-table \
  --table-name tfstate-lock-bedrock-finops \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1
```

### ステップ 3: 機密情報の登録

```bash
# Chatwork API トークン（Secrets Manager）
aws secretsmanager create-secret \
  --name "bedrock-finops-automation/chatwork-api-token" \
  --secret-string '{"api_token":"YOUR_CHATWORK_API_TOKEN"}' \
  --region ap-northeast-1

# Chatwork ルーム ID（SSM Parameter Store: 無料）
aws ssm put-parameter \
  --name "/bedrock-finops-automation/chatwork-room-id" \
  --value "YOUR_ROOM_ID" \
  --type "String" \
  --region ap-northeast-1
```

### ステップ 4: terraform.tfvars の編集

```hcl
# environments/dev/terraform.tfvars
aws_region   = "ap-northeast-1"
environment  = "dev"
project_name = "bedrock-finops-automation"
owner        = "your-name"   # 自分の名前に変更
cost_center  = "personal"
```

### ステップ 5: PR を作成してデプロイ

```bash
git checkout -b setup/initial
git add .
git commit -m "Initial infrastructure"
git push origin setup/initial
# → PR を作成すると GitHub Actions が自動で terraform plan を実行し結果を PR コメントに投稿
# → main にマージすると terraform apply が自動実行
```

### ステップ 6: 統合テスト

デプロイ完了後、GitHub Actions > `Integration Test` > `Run workflow` を手動実行して
Step Functions のエンドツーエンド動作を確認する。

```bash
# または AWS CLI から直接実行（前月データを対象）
aws stepfunctions start-execution \
  --state-machine-arn "$(cd environments/dev && terraform output -raw state_machine_arn)" \
  --input '{}'
```

### ステップ 7: 月次自動実行の有効化

統合テストが成功したら、スケジューラーを有効化する。

```hcl
# environments/dev/main.tf
module "scheduler" {
  # ...
  enabled = true  # false → true に変更
}
```

```bash
git commit -m "Enable monthly scheduler"
# PR → main マージで自動適用
```

---

## IAM 権限について

**root ログイン不要。アクセスキーも不要（OIDC 認証）。**

| 実行方法 | 必要な権限 |
|---|---|
| GitHub Actions（推奨） | OIDC ロール（bootstrap/ で作成・AdministratorAccess） |
| ローカル手動実行 | IAM ユーザー（PowerUserAccess + IAMFullAccess） |

各 Lambda には最小権限の IAM ロールが個別に付与される。

---

## モジュール設計詳細

### Week 1: storage / collector / anomaly-detector

#### storage

| リソース | 設計ポイント |
|---|---|
| S3 | バージョニング有効・SSE-S3 暗号化・パブリックアクセス全ブロック |
| S3 ライフサイクル | 90 日で Glacier 移行・365 日で削除・旧バージョン 30 日で削除 |
| DynamoDB | PAY_PER_REQUEST（月 1 回書き込みのためプロビジョンド不要）・PITR 有効・TTL 設定 |

#### collector

Lambda が Cost Explorer API を呼び出す際の注意点:

```
Cost Explorer のエンドポイントは us-east-1 固定のため、
boto3 クライアント生成時に region_name='us-east-1' を明示的に指定する。
Lambda 自体は ap-northeast-1 で動作する。
```

Secrets Manager から機密情報を取得するパターンを実装済み（`get_secret()` 関数）。
chatwork-notifier 等の他 Lambda でも同じパターンを使用する。

IAM 最小権限の例:

| アクション | スコープ |
|---|---|
| `ce:GetCostAndUsage` | `*`（Cost Explorer はリソース指定不可） |
| `s3:PutObject` / `s3:GetObject` | `{bucket_arn}/raw/*` のみ |
| `dynamodb:PutItem` / `dynamodb:UpdateItem` | 対象テーブル ARN のみ |
| `secretsmanager:GetSecretValue` | `arn:...:secret:{project_name}/*` のみ |

#### anomaly-detector

```
前月コストが $0.01 未満の場合はスキップ（新規アカウントのノイズ回避）
総コストが $1.00 未満の場合の集中度チェックはスキップ
新規サービスのコストが $0.10 未満は無視（無料枠・トライアルの誤検知防止）
```

---

### Week 2: ai-reporter / html-formatter / chatwork-notifier

#### ai-reporter

Bedrock 呼び出し時のコスト削減工夫:

- サービス別上位を 10 件から **5 件**に絞ってプロンプトを圧縮
- `temperature: 0.3`（低め設定でコスト分析の一貫性を保つ）
- `max_tokens: 1024`（上限を明示して出力コストを制御）
- 使用 tokens を CloudWatch Logs に記録（コスト監視用）
- JSON パース失敗時のフォールバック処理あり（ワークフローを止めない）

IAM の `bedrock:InvokeModel` はモデル ARN レベルで制限済み（Haiku のみ許可）:

```
arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0
```

#### html-formatter

- 標準ライブラリのみで HTML 生成（外部テンプレートエンジン不使用 = Lambda サイズ最小）
- XSS 対策の HTML エスケープ処理あり（`_escape()` 関数）
- S3 署名付き URL（有効期限 7 日間）を生成して Chatwork リンクに使用

#### chatwork-notifier

Chatwork API トークンと Chatwork ルーム ID の保管先を意図的に分けている:

| 情報 | 保管先 | 理由 |
|---|---|---|
| Chatwork API トークン | Secrets Manager | 機密情報のため暗号化保管が必須 |
| Chatwork ルーム ID | SSM Parameter Store | 機密性が低く、Secrets Manager（$0.40/月）を節約できる |

外部 HTTP 通信に `urllib`（標準ライブラリ）を使用。`requests` 等の外部ライブラリ不要。

---

### Week 3: workflow / scheduler

#### Step Functions の設計判断

| 項目 | 決定 | 理由 |
|---|---|---|
| Workflow タイプ | Standard | 実行履歴を最大 1 年保持できる（Express は 90 日）。月次監査証跡として活用 |
| ログレベル | ERROR のみ | ALL にすると全実行の入出力が記録されコストが増加する |
| ai-reporter のリトライ間隔 | 10 秒 | Bedrock スロットリング（429）への対応 |
| dev 環境スケジュール | `enabled = false` | デプロイ直後の誤発動を防止。テスト完了後に `true` に変更する |

#### ASL 定義の Lambda ARN 注入方法

`definition.asl.json.tftpl` を Terraform の `templatefile()` で処理し、各 Lambda ARN を注入する。

```hcl
definition = templatefile("${path.module}/definition.asl.json.tftpl", {
  collector_lambda_arn         = var.collector_lambda_arn
  anomaly_detector_lambda_arn  = var.anomaly_detector_lambda_arn
  # ...
})
```

#### OutputPath パターン（Lambda 返り値の取り出し）

Step Functions で Lambda を呼び出すと結果が `Payload` にラップされる。
`ResultPath: "$"` + `OutputPath: "$.Payload"` の組み合わせで Lambda の返り値だけを次ステートに渡す。

```json
"ResultPath": "$",
"OutputPath": "$.Payload"
```

---

### Week 4: GitHub Actions CI/CD / 統合テスト

#### CI/CD パイプライン

```
PR 作成・更新
  │
  ├──▶ unit-test（Python pytest）
  │
  └──▶ terraform-plan（unit-test 成功後）
        ├── terraform init
        ├── terraform fmt -check
        ├── terraform validate
        └── terraform plan → 結果を PR コメントに自動投稿
              （既存コメントがあれば上書き更新）

main マージ
  │
  ├──▶ unit-test
  │
  └──▶ terraform-apply（concurrency 制御で同時実行防止）
        └── terraform apply -auto-approve
```

#### 統合テスト（integration-test.yml）

手動実行で Step Functions をエンドツーエンドで検証する:

1. Step Functions 実行を開始
2. 30 秒間隔でポーリング（最大 10 分）
3. 完了後、S3 に以下 5 ファイルが生成されたことを確認

```
raw/{YYYY-MM}/current_month.json    ← コスト生データ
raw/{YYYY-MM}/prev_month.json       ← 前月生データ
anomaly/{YYYY-MM}/anomaly_report.json ← 異常検知結果
ai-report/{YYYY-MM}/analysis.json   ← AI 所見
html/{YYYY-MM}/report.html          ← 最終 HTML レポート
```

#### ユニットテスト

`modules/anomaly-detector/tests/test_index.py` に 23 件のテストを実装。

主なテスト観点:

| クラス | テスト内容 |
|---|---|
| `TestDetectCostIncrease` | MEDIUM/HIGH 境界値・ゼロ除算ガード・減少時の非検知 |
| `TestDetectServiceConcentration` | 60% 境界値・小額コストのスキップ |
| `TestDetectNewServices` | $0.10 境界値・複数同時検知・既存サービスの非検知 |
| `TestRunAnomalyDetection` | 複数ルール同時検知・正常月の空リスト返却 |
| `TestHandlerWithMocks` | AWS API をモックしてハンドラ全体を検証 |

```bash
# ローカルで実行
pip install pytest pytest-cov boto3
pytest modules/ -v
```

---

## 異常検知ルール

| ルール | 閾値 | 重要度 |
|---|---|---|
| 前月比コスト増加 | 20% 超 | MEDIUM |
| 前月比コスト増加 | 50% 超 | HIGH |
| 単一サービス集中度 | 総コストの 60% 超 | MEDIUM |
| 新規サービス出現 | $0.10 以上のコスト発生 | LOW |

閾値は Terraform 変数で変更可能。

```hcl
# environments/dev/main.tf
module "anomaly_detector" {
  source = "../../modules/anomaly-detector"
  # ...
  medium_threshold_pct                = 20  # デフォルト
  high_threshold_pct                  = 50  # デフォルト
  service_concentration_threshold_pct = 60  # デフォルト
}
```

---

## Amazon Bedrock の利用について

### 使用する機能

このプロジェクトで使う Bedrock 機能は **InvokeModel API（テキスト生成）のみ**。

```
Amazon Bedrock
  └── Inference（モデル呼び出し）
        └── Claude 3 Haiku（anthropic.claude-3-haiku-20240307-v1:0）
```

Knowledge Base・Agent・Fine-tuning など多数の機能が Bedrock には存在するが、
月次レポート生成という用途では**シンプルなテキスト生成で十分**なためこれのみを使用する。

### ai-reporter での呼び出し実装

```python
import boto3

bedrock = boto3.client("bedrock-runtime", region_name="ap-northeast-1")

response = bedrock.invoke_model(
    modelId="anthropic.claude-3-haiku-20240307-v1:0",
    body=json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1024,
        "temperature": 0.3,
        "messages": [
            {
                "role": "user",
                "content": f"以下のAWSコストデータを分析して所見と改善提案を生成してください:\n{cost_summary}"
            }
        ]
    })
)
```

### モデル選定理由（Haiku を選ぶ理由）

| モデル | 入力 / 1K tokens | 出力 / 1K tokens | 月1回の費用 | 採用 |
|---|---|---|---|---|
| Claude 3 Haiku | $0.00025 | $0.00125 | $0.001 未満 | ✓ |
| Claude 3 Sonnet | $0.003 | $0.015 | 約 $0.01 | — |
| Claude 3 Opus | $0.015 | $0.075 | 約 $0.05 | — |

月次レポート生成（プロンプト ~1,000 tokens + 出力 ~500 tokens）は軽量タスクのため、
Haiku で品質的に十分。**Sonnet / Opus の使用はコスト最適化の観点から禁止**。

### 使わない Bedrock 機能と理由

| 機能 | 不使用の理由 |
|---|---|
| Knowledge Base | 外部ドキュメント参照不要。コストデータはプロンプトに直接埋め込む |
| Bedrock Agent | 自律的なツール呼び出し不要。処理フローは Step Functions が管理する |
| Guardrails | 個人利用・社内通知のみのため過剰 |
| Fine-tuning | 汎用的なコスト分析にはベースモデルで十分 |

---

## セキュリティ設計

| 観点 | 対応内容 |
|---|---|
| 認証 | アクセスキー禁止。GitHub Actions は OIDC、Lambda は IAM ロールで認証 |
| Confused Deputy 防止 | 全 Lambda の AssumeRole に `aws:SourceAccount` 条件を付与 |
| 最小権限 IAM | Lambda ごとに個別ロール。`ce:GetCostAndUsage` のみ、S3 は prefix スコープ等 |
| Secrets Manager スコープ | `arn:...:secret:{project_name}/*` のみアクセス可（他プロジェクトの参照不可） |
| S3 パブリックアクセス | 4 項目すべてブロック |
| 暗号化 | S3: SSE-S3（AES256）、DynamoDB: AWS 管理キー |
| ログ保持 | CloudWatch Logs 30 日（無制限放置を防止） |
| XSS 対策 | html-formatter の `_escape()` 関数で HTML エスケープ処理 |

---

## 構築スケジュール

| Week | 対象 | 状態 |
|---|---|---|
| 1 | storage + collector + anomaly-detector | 完了 |
| 2 | ai-reporter + html-formatter + chatwork-notifier | 完了 |
| 3 | workflow（Step Functions）+ scheduler（EventBridge） | 完了 |
| 4 | GitHub Actions CI/CD + 統合テスト | 完了 |

---

## タグ戦略

全リソースに以下のタグを付与（`default_tags` で自動適用）。

```hcl
Environment = "dev"
Project     = "bedrock-finops-automation"
Owner       = "your-name"
CostCenter  = "personal"
```

---

## 設計原則

1. **セキュリティ**: アクセスキー禁止・最小権限 IAM・機密情報は Secrets Manager
2. **コスト**: AI モデルは Haiku 固定（Sonnet / Opus 使用禁止）・Lambda メモリ 512MB 以下
3. **再現性**: 全リソース Terraform 管理・手動操作禁止
4. **学習目的**: コードにコメントを丁寧に記載
