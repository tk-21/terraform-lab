# bedrock-finops-automation

AWS Cost Explorer と Amazon Bedrock（Claude Haiku）を使って、月次コストレポートを自動生成・Chatwork 通知する FinOps 自動化基盤。

毎月1日に自動実行され、コスト集計・異常検知・AI 所見生成・HTML レポート保存・Chatwork 通知までを全自動で行う。

---

## 何ができるのか

毎月1日 09:00 JST に以下が自動実行される。

1. **コスト収集** — Cost Explorer API で当月・前月のコストデータを取得
2. **異常検知** — 前月比増加・サービス集中・新規サービス出現を自動検知
3. **AI 所見生成** — Bedrock（Claude Haiku）がコストデータを分析し、所見と改善提案を生成
4. **HTML レポート保存** — 整形済みレポートを S3 に保存（90 日後 Glacier 移行）
5. **Chatwork 通知** — 要約と署名付き S3 リンクを Chatwork に通知

### 通知メッセージのイメージ

```
AWS FinOps 月次コストレポート 2025-01

■ コスト概要
  当月合計: $123.45
  前月合計: $100.00
  前月比:   +23.5%（上昇）

■ 異常検知（2件）
  [要対応] HIGH: 1件
  [注意] MEDIUM: 1件
  ■ 前月比 23.5% のコスト増加を検知

■ AI 所見（リスクレベル: HIGH）
  EC2 と RDS のコストが急増しており...

詳細レポート（7日間有効）
https://...s3.amazonaws.com/html/2025-01/report.html
```

---

## アーキテクチャ

```
EventBridge（毎月1日 09:00 JST）
  │
  ▼
Step Functions ステートマシン
  │
  ├──▶ collector         Cost Explorer API でコストデータ収集 → S3 / DynamoDB
  ├──▶ anomaly-detector  前月比・スパイク・サービス集中度を検知 → S3
  ├──▶ ai-reporter       Bedrock（Claude Haiku）で AI 所見生成 → S3
  ├──▶ html-formatter    HTML レポート整形 → S3 保存 + 署名付き URL 生成
  └──▶ chatwork-notifier 要約 + S3 リンクを Chatwork に通知
```

各ステートは前のステートの出力を受け取り、情報を追加して次に渡す。
生データは S3 に保存し、Step Functions には S3 キーとサマリーのみを流す（256KB 制限対策）。

エラー発生時はいずれのステートからも Fail ステートに遷移する。
各ステートにリトライ（最大 2 回・指数バックオフ）を設定済み。

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

## セットアップ手順

### 前提条件

- Terraform >= 1.5.0
- AWS CLI（設定済み）
- IAM 権限: PowerUserAccess + IAMFullAccess 以上
- GitHub リポジトリ（GitHub Actions 実行用）

---

### ステップ 1: GitHub Actions 用 OIDC ロールを作成する（初回のみ）

アクセスキーを使わず OIDC で GitHub Actions を認証するための IAM ロールを作成する。

```bash
cd bootstrap/
terraform init
terraform apply -var="github_owner=YOUR_GITHUB_USERNAME"
```

出力された ARN を GitHub リポジトリの Secrets に登録する。

```
Settings > Secrets and variables > Actions > New repository secret
  Name:  AWS_ROLE_ARN
  Value: (terraform output の github_actions_role_arn)
```

---

### ステップ 2: Terraform バックエンド用リソースを作成する

`terraform init` より先に S3・DynamoDB を手動作成する。

```bash
aws s3 mb s3://tfstate-bedrock-finops-automation --region ap-northeast-1

aws dynamodb create-table \
  --table-name tfstate-lock-bedrock-finops \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1
```

---

### ステップ 3: 機密情報を登録する

```bash
# Chatwork API トークン（Secrets Manager）
aws secretsmanager create-secret \
  --name "bedrock-finops-automation/chatwork-api-token" \
  --secret-string '{"api_token":"YOUR_CHATWORK_API_TOKEN"}' \
  --region ap-northeast-1

# Chatwork ルーム ID（SSM Parameter Store）
aws ssm put-parameter \
  --name "/bedrock-finops-automation/chatwork-room-id" \
  --value "YOUR_ROOM_ID" \
  --type "String" \
  --region ap-northeast-1
```

---

### ステップ 4: terraform.tfvars を編集する

```hcl
# environments/dev/terraform.tfvars
aws_region   = "ap-northeast-1"
environment  = "dev"
project_name = "bedrock-finops-automation"
owner        = "your-name"
cost_center  = "personal"
```

---

### ステップ 5: PR を作成してデプロイする

```bash
git checkout -b setup/initial
git add .
git commit -m "Initial infrastructure"
git push origin setup/initial
```

PR を作成すると GitHub Actions が自動で `terraform plan` を実行し、結果を PR コメントに投稿する。
main にマージすると `terraform apply` が自動実行される。

---

### ステップ 6: 統合テストを実行する

デプロイ完了後、GitHub Actions > `Integration Test` > `Run workflow` を手動実行して Step Functions のエンドツーエンド動作を確認する。

```bash
# または AWS CLI から直接実行
aws stepfunctions start-execution \
  --state-machine-arn "$(cd environments/dev && terraform output -raw state_machine_arn)" \
  --input '{}'
```

以下 5 ファイルが S3 に生成されれば成功。

```
raw/{YYYY-MM}/current_month.json
raw/{YYYY-MM}/prev_month.json
anomaly/{YYYY-MM}/anomaly_report.json
ai-report/{YYYY-MM}/analysis.json
html/{YYYY-MM}/report.html
```

---

### ステップ 7: 月次自動実行を有効化する

統合テストが成功したら、スケジューラーを有効化する。

```hcl
# environments/dev/main.tf
module "scheduler" {
  # ...
  enabled = true  # false → true に変更
}
```

変更を main にマージすると自動適用される。

---

## 異常検知ルール

| ルール | 閾値 | 重要度 |
|---|---|---|
| 前月比コスト増加 | 20% 超 | MEDIUM |
| 前月比コスト増加 | 50% 超 | HIGH |
| 単一サービス集中度 | 総コストの 60% 超 | MEDIUM |
| 新規サービス出現 | $0.10 以上のコスト発生 | LOW |

閾値は `environments/dev/main.tf` の変数で変更可能。

---

## 月次ランニングコスト

**合計: 約 $0.42 / 月（約 60 円 / 月）**

| サービス | 月額 |
|---|---|
| Secrets Manager（Chatwork API トークン） | $0.40 |
| Cost Explorer API（2 回/月） | $0.02 |
| Lambda / Step Functions / S3 / DynamoDB / EventBridge | $0.00（無料枠） |
| Bedrock（Haiku、月 1 回 ~2,000 tokens） | $0.00（$0.001 未満） |

> Secrets Manager の $0.40/月 を節約したい場合は SSM Parameter Store の SecureString（無料）に変更できる。

S3 ライフサイクル: 90 日後 Glacier 移行 → 365 日後自動削除。

---

## セキュリティ設計

| 観点 | 対応内容 |
|---|---|
| 認証 | アクセスキー禁止。GitHub Actions は OIDC、Lambda は IAM ロールで認証 |
| 最小権限 IAM | Lambda ごとに個別ロール。S3 アクセスは prefix スコープ限定 |
| Secrets Manager スコープ | `{project_name}/*` のみアクセス可 |
| S3 | パブリックアクセス全ブロック・SSE-S3 暗号化 |
| XSS 対策 | html-formatter で HTML エスケープ処理済み |
| ログ保持 | CloudWatch Logs 30 日（無制限放置を防止） |

---

## CI/CD パイプライン

```
PR 作成・更新
  ├──▶ pytest（ユニットテスト）
  └──▶ terraform plan → 結果を PR コメントに自動投稿

main マージ
  └──▶ terraform apply（concurrency 制御で同時実行防止）
```

ユニットテストはローカルでも実行できる。

```bash
pip install pytest pytest-cov boto3
pytest modules/ -v
```
