# aws-infra-review-ai

Terraform コードまたは AWS アーキテクチャ図を投入すると、4 つの専門 AI エージェントが並列でレビューし、スーパーバイザーが統合した最終レポートを生成するマルチエージェント型インフラレビュー基盤。

```
あなた（TFコード or アーキテクチャ図）
  │
  ▼
API Gateway（POST /reviews）
  │
  ▼
S3 にアップロード
  │ S3 イベント
  ▼
Step Functions（並列レビュー開始）
  │
  ├── security-reviewer   ── Bedrock Claude
  ├── cost-reviewer       ── Bedrock Claude
  ├── reliability-reviewer── Bedrock Claude
  └── operations-reviewer ── Bedrock Claude
  │
  ▼
supervisor（統合・トレードオフ解消）── Bedrock Claude
  │
  ├── HTML レポート生成 → S3 保存
  │
  └── Chatwork 通知（スコア + レポートリンク）
```

---

## 目次

- [前提条件](#前提条件)
- [初回セットアップ](#初回セットアップ)
- [デプロイ](#デプロイ)
- [使い方](#使い方)
- [GitHub Actions CI/CD](#github-actions-cicd)
- [アーキテクチャ図レビュー（画像対応）](#アーキテクチャ図レビュー画像対応)
- [レビュー結果の確認](#レビュー結果の確認)
- [モニタリング・アラーム設定](#モニタリングアラーム設定)
- [コスト目安](#コスト目安)
- [トラブルシューティング](#トラブルシューティング)

---

## 前提条件

| ツール | バージョン | 確認コマンド |
|--------|-----------|-------------|
| Terraform | >= 1.5.0 | `terraform version` |
| AWS CLI | >= 2.0 | `aws --version` |
| curl / jq | 任意 | `curl --version` |

**AWS 側の準備:**

- Bedrock で `anthropic.claude-3-5-sonnet-20241022-v2:0` のモデルアクセスを有効化
  - コンソール: `Amazon Bedrock` → `モデルアクセス` → Anthropic Claude 3.5 Sonnet を申請・有効化
  - リージョン: `ap-northeast-1`（東京）

- Terraform ステートバックエンド用の S3 バケットと DynamoDB テーブルを作成

```bash
# ステートバックエンドの作成（初回のみ）
aws s3api create-bucket \
  --bucket tfstate-aws-infra-review-ai \
  --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1

aws s3api put-bucket-versioning \
  --bucket tfstate-aws-infra-review-ai \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name tfstate-lock-aws-infra-review-ai \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1
```

---

## 初回セットアップ

### 1. リポジトリをクローン

```bash
git clone https://github.com/your-org/aws-infra-review-ai.git
cd aws-infra-review-ai
```

### 2. tfvars を設定

```bash
cp environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars
# または直接作成:
cat > environments/dev/terraform.tfvars << 'EOF'
aws_region    = "ap-northeast-1"
environment   = "dev"
project_name  = "aws-infra-review-ai"
owner         = "your-name"

# Chatwork 通知（任意。設定しなければスキップされる）
# chatwork_api_token = "xxxxxxxxxxxx"
# chatwork_room_id   = "123456789"

# CloudWatch アラームのメール通知先（任意。apply 後に確認メールの承認が必要）
# alarm_email = "your-email@example.com"

# GitHub Actions OIDC（GitHub Actions を使う場合に設定）
# github_repository = "your-org/aws-infra-review-ai"
EOF
```

### 3. Terraform 初期化

```bash
cd environments/dev
terraform init
```

---

## デプロイ

```bash
cd environments/dev

# プラン確認
terraform plan

# 適用（約 2〜3 分）
terraform apply
```

**主要な出力値を確認する:**

```bash
terraform output
```

```
api_endpoint                  = "https://xxxx.execute-api.ap-northeast-1.amazonaws.com/dev/reviews"
input_bucket_id               = "aws-infra-review-ai-review-input-dev-123456789012"
state_machine_arn             = "arn:aws:states:ap-northeast-1:...:stateMachine:aws-infra-review-ai-review-workflow-dev"
chatwork_token_ssm_path       = "/aws-infra-review-ai/dev/chatwork/api_token"
alarm_sns_topic_arn           = "arn:aws:sns:ap-northeast-1:...:aws-infra-review-ai-alarms-dev"
```

> **Chatwork を使う場合**: デプロイ後に SSM Parameter Store でトークンを設定する
>
> ```bash
> aws ssm put-parameter \
>   --name "/aws-infra-review-ai/dev/chatwork/api_token" \
>   --value "YOUR_CHATWORK_API_TOKEN" \
>   --type SecureString \
>   --overwrite \
>   --region ap-northeast-1
> ```

---

## 使い方

### Terraform コードをレビューする

#### ステップ 1: セッションを作成してアップロード URL を取得

```bash
API_ENDPOINT=$(cd environments/dev && terraform output -raw api_endpoint)

RESPONSE=$(curl -s -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "input_type": "terraform",
    "filename": "main.tf"
  }')

echo $RESPONSE | jq .
```

**レスポンス例:**

```json
{
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "upload_url": "https://aws-infra-review-ai-review-input-dev-xxx.s3.amazonaws.com/reviews/a1b2c3.../main.tf?...",
  "s3_key": "reviews/a1b2c3d4-.../main.tf",
  "status": "pending"
}
```

#### ステップ 2: ファイルをアップロード（レビュー自動開始）

```bash
SESSION_ID=$(echo $RESPONSE | jq -r '.session_id')
UPLOAD_URL=$(echo $RESPONSE | jq -r '.upload_url')

# レビューしたいファイルをアップロード
curl -X PUT "$UPLOAD_URL" \
  --upload-file /path/to/your/main.tf

echo "レビュー開始！セッション ID: $SESSION_ID"
```

アップロードした瞬間に S3 イベントが発火し、Step Functions が自動で起動する。

#### ステップ 3: 進捗・結果を確認

**API で確認する（推奨）:**

```bash
curl -s "$API_ENDPOINT/$SESSION_ID" | jq .
```

**レビュー中（`running`）のレスポンス例:**

```json
{
  "session_id": "a1b2c3d4-...",
  "status": "running",
  "input_type": "terraform",
  "created_at": "2025-01-01T12:00:00+00:00"
}
```

**完了後（`completed`）のレスポンス例:**

```json
{
  "session_id": "a1b2c3d4-...",
  "status": "completed",
  "input_type": "terraform",
  "created_at": "2025-01-01T12:00:00+00:00",
  "scores": {
    "security": 72,
    "cost": 85,
    "reliability": 60,
    "operations": 78,
    "total": 72.5
  },
  "executive_summary": "全体的にセキュリティと可用性に改善余地があります。...",
  "priority_actions": ["MFA 強制を IAM ポリシーで設定する", "..."],
  "final_report_url": "https://s3.amazonaws.com/.../report.html?..."
}
```

**DynamoDB で直接確認することもできる:**

```bash
TABLE_NAME=$(cd environments/dev && terraform output -raw review_table_name)

aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"session_id\": {\"S\": \"$SESSION_ID\"}}" \
  --region ap-northeast-1 \
  | jq '.Item.status.S'
```

**ステータスの意味:**

| ステータス | 説明 |
|-----------|------|
| `pending` | セッション作成済み、ファイル未アップロード |
| `starting` | ワークフロー起動中 |
| `running` | 4 エージェントが並列レビュー中 |
| `completed` | レビュー完了（HTML レポートあり） |
| `failed` | エラー発生（CloudWatch Logs を確認） |

**所要時間の目安:** アップロード後 **約 60〜90 秒** で `completed` になる。

---

## GitHub Actions CI/CD

### セットアップ

#### 1. OIDC IAM ロールをデプロイ（初回のみ）

```bash
# terraform.tfvars に github_repository を追加
echo 'github_repository = "your-org/aws-infra-review-ai"' >> environments/dev/terraform.tfvars

cd environments/dev

# OIDC リソースだけ先に apply（ローカルの AWS 認証情報を使用）
terraform apply \
  -target=aws_iam_openid_connect_provider.github \
  -target=aws_iam_role.github_actions \
  -target=aws_iam_role_policy.github_actions_terraform

# ロール ARN を確認
terraform output github_actions_role_arn
```

#### 2. GitHub Secrets を登録

リポジトリの **Settings → Secrets and variables → Actions** で以下を登録:

| Secret 名 | 値 | 必須 |
|----------|---|------|
| `TF_ROLE_ARN` | `terraform output github_actions_role_arn` の出力値 | 必須 |
| `CHATWORK_API_TOKEN` | Chatwork API トークン | 任意 |
| `CHATWORK_ROOM_ID` | Chatwork ルーム ID | 任意 |

#### 3. 動作確認

```bash
# 適当な tf ファイルを変更して PR を作成
git checkout -b feature/test-ci
echo "# test" >> modules/storage/main.tf
git add -A && git commit -m "test: CI 確認用"
git push origin feature/test-ci
# → PR を作成すると terraform plan が自動実行され、結果がコメントに投稿される
```

### CI/CD フロー

```
PR 作成・更新
  └── plan ジョブ
        ├── terraform fmt -check
        ├── terraform validate
        ├── terraform plan
        └── PR にコメント投稿（既存コメントを更新）

main へのマージ
  └── plan ジョブ（再実行）
        └── apply ジョブ（plan artifact を使って apply）
```

---

## アーキテクチャ図レビュー（画像対応）

PNG/JPG/WEBP/GIF/PDF 形式のアーキテクチャ図もレビューできる。
Bedrock Claude の Vision API が自動的にテキスト説明に変換し、各エージェントがレビューする。

```bash
# ステップ 1: セッション作成（input_type を "architecture" にする）
RESPONSE=$(curl -s -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "input_type": "architecture",
    "filename": "architecture.png"
  }')

UPLOAD_URL=$(echo $RESPONSE | jq -r '.upload_url')

# ステップ 2: 画像をアップロード（PNG/JPG/WEBP/GIF/PDF 対応）
curl -X PUT "$UPLOAD_URL" \
  --upload-file /path/to/architecture.png
```

**対応形式と制限:**

| 形式 | 拡張子 | 最大サイズ |
|------|-------|-----------|
| 画像 | `.png` `.jpg` `.jpeg` `.webp` `.gif` | 3 MB |
| PDF | `.pdf` | 3 MB |
| テキスト | `.tf` `.json` `.yaml` `.txt` など | 100 KB |

> テキストは 100KB に制限しています（Step Functions の 256KB ペイロード上限に対して、4 エージェント結果が加わる分の余裕を確保するため）。大きなファイルはモジュールごとに分割してレビューしてください。

---

## API リファレンス

| メソッド | パス | 説明 |
|---------|------|------|
| `POST` | `/reviews` | レビューセッションを作成し、S3 アップロード URL を返す |
| `GET` | `/reviews/{session_id}` | セッションの進捗・レビュー結果を取得する |

### POST /reviews

**リクエスト:**

```json
{
  "input_type": "terraform",
  "filename": "main.tf"
}
```

| フィールド | 型 | 必須 | 説明 |
|-----------|---|------|------|
| `input_type` | string | ✓ | `"terraform"` または `"architecture"` |
| `filename` | string | | アップロードするファイル名（デフォルト: `"review.tf"`） |

**レスポンス (201):**

```json
{
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "upload_url": "https://...s3...?...",
  "s3_key": "reviews/a1b2c3d4-.../main.tf",
  "status": "pending",
  "message": "upload_url に main.tf をアップロードしてください。..."
}
```

### GET /reviews/{session_id}

**レスポンス (200):**

| フィールド | 含まれるタイミング | 説明 |
|-----------|------------------|------|
| `session_id` | 常時 | セッション ID |
| `status` | 常時 | `pending` / `starting` / `running` / `completed` / `failed` |
| `input_type` | 常時 | `terraform` / `architecture` |
| `created_at` | 常時 | セッション作成日時（ISO 8601） |
| `scores` | `completed` のみ | `{ security, cost, reliability, operations, total }` (0〜100) |
| `executive_summary` | `completed` のみ | エグゼクティブサマリー |
| `priority_actions` | `completed` のみ | 優先対応アクションリスト |
| `final_report_url` | `completed` のみ | HTML レポートの署名付き URL（7 日間有効） |

---

## レビュー結果の確認

### HTML レポート（推奨）

`completed` になったら DynamoDB の `final_report_url` にアクセスする（7 日間有効）:

```bash
REPORT_URL=$(aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"session_id\": {\"S\": \"$SESSION_ID\"}}" \
  --region ap-northeast-1 \
  | jq -r '.Item.final_report_url.S')

echo "レポート URL: $REPORT_URL"
# → ブラウザで開く
```

レポートに含まれる情報:
- 各エージェントのスコア（0〜100）と総合スコア
- エグゼクティブサマリー（3 文以内）
- 優先対応アクション TOP 10
- セキュリティ vs コストなどのトレードオフ分析
- エージェント別詳細 findings（severity 別色分け）

### Step Functions の実行履歴を確認

```bash
STATE_MACHINE_ARN=$(cd environments/dev && terraform output -raw state_machine_arn)

aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --region ap-northeast-1 \
  | jq '.executions[] | {name, status, startDate, stopDate}'
```

### CloudWatch Logs でデバッグ

```bash
# workflow-starter のログ（S3 トリガー確認）
aws logs tail "/aws/lambda/aws-infra-review-ai-workflow-starter-dev" \
  --follow --region ap-northeast-1

# 特定エージェントのログ
aws logs tail "/aws/lambda/aws-infra-review-ai-security-reviewer-dev" \
  --follow --region ap-northeast-1
```

---

## モニタリング・アラーム設定

### CloudWatch アラーム

以下の 4 つのアラームが自動で作成される:

| アラーム | 検知する異常 |
|---------|------------|
| `sf-executions-failed` | Step Functions ワークフロー全体の失敗 |
| `sf-executions-timed-out` | ワークフローのタイムアウト |
| `workflow-starter-errors` | S3 → Step Functions 起動フェーズの Lambda エラー |
| `supervisor-errors` | 4 エージェント統合フェーズの Lambda エラー |

### メール通知を有効にする

`terraform.tfvars` に `alarm_email` を設定して `terraform apply` するだけ:

```hcl
alarm_email = "your-email@example.com"
```

> apply 後に AWS から確認メールが届く。**メール内の "Confirm subscription" リンクをクリックして承認**しないと通知が届かない。

### アラーム状態を確認する

```bash
# 全アラームの状態一覧
aws cloudwatch describe-alarms \
  --alarm-name-prefix "aws-infra-review-ai" \
  --region ap-northeast-1 \
  | jq '.MetricAlarms[] | {name: .AlarmName, state: .StateValue}'
```

### SNS トピック ARN を確認する

```bash
terraform output alarm_sns_topic_arn
```

メール以外の通知先（Slack Lambda・PagerDuty など）を追加する場合は、この SNS トピックにサブスクリプションを追加する。

---

## コスト目安

1 回のレビュー実行あたりの概算（dev 環境）:

| サービス | 用途 | 概算コスト |
|---------|------|-----------|
| Bedrock Claude 3.5 Sonnet | 4 エージェント + supervisor | 約 $0.09 |
| Bedrock Claude 3.5 Sonnet | 画像前処理（アーキテクチャ図の場合） | 約 $0.02 |
| Step Functions | Standard Workflow 遷移 | 約 $0.001 |
| Lambda | 6 関数 × 約 30〜60 秒 | 約 $0.001 |
| S3 | 入力ファイル + HTML レポート | 約 $0.001 |
| DynamoDB | PAY_PER_REQUEST | 約 $0.001 |

**合計: 1 レビューあたり約 $0.09〜0.12（約 14〜18 円）**

月 100 回レビューしても約 $10 程度。

---

## トラブルシューティング

### レビューが `failed` になる

```bash
# Step Functions の実行詳細を確認
aws stepfunctions get-execution-history \
  --execution-arn "arn:aws:states:ap-northeast-1:ACCOUNT:execution:aws-infra-review-ai-review-workflow-dev:review-SESSION_ID" \
  --region ap-northeast-1 \
  | jq '.events[] | select(.type | contains("Failed")) | .taskFailedEventDetails'
```

よくある原因:
- **Bedrock モデルアクセス未申請** → AWS コンソールでモデルアクセスを有効化
- **Lambda タイムアウト** → Bedrock の応答が 60 秒を超えた。大きなファイルは分割を検討
- **IAM 権限不足** → CloudWatch Logs でエラーコードを確認

### S3 アップロード後にワークフローが起動しない

```bash
# workflow-starter のログを確認
aws logs tail "/aws/lambda/aws-infra-review-ai-workflow-starter-dev" \
  --since 5m --region ap-northeast-1
```

よくある原因:
- セッションのステータスがすでに `starting` / `running` / `completed`（重複アップロードはスキップ）
- S3 キーのプレフィックスが `reviews/` で始まっていない

### Chatwork に通知が届かない

```bash
# chatwork-notifier のログを確認
aws logs tail "/aws/lambda/aws-infra-review-ai-chatwork-notifier-dev" \
  --since 5m --region ap-northeast-1

# SSM Parameter Store のトークンを確認
aws ssm get-parameter \
  --name "/aws-infra-review-ai/dev/chatwork/api_token" \
  --with-decryption \
  --region ap-northeast-1 \
  | jq '.Parameter.Value'
```

> Chatwork 通知は失敗してもワークフロー全体は `completed` になる（ノンブロッキング設計）。

### terraform plan が認証エラーになる

```bash
# AWS 認証情報の確認
aws sts get-caller-identity

# GitHub Actions では TF_ROLE_ARN が正しく設定されているか確認
# リポジトリ Settings → Secrets → TF_ROLE_ARN
```

---

## ディレクトリ構成

```
aws-infra-review-ai/
├── .github/workflows/
│   └── terraform.yml          # CI/CD（OIDC + plan on PR + apply on main）
├── environments/
│   └── dev/
│       ├── main.tf            # 全モジュールの呼び出し
│       ├── github-actions.tf  # OIDC プロバイダー + IAM ロール
│       ├── variables.tf
│       ├── outputs.tf
│       ├── terraform.tfvars   # 環境固有の値（git 管理外推奨）
│       └── backend.tf         # S3 リモートステート
└── modules/
    ├── storage/               # S3 + DynamoDB
    ├── api/                   # API Gateway + session-handler Lambda
    ├── agents/
    │   ├── security-reviewer/
    │   ├── cost-reviewer/
    │   ├── reliability-reviewer/
    │   ├── operations-reviewer/
    │   └── supervisor/        # 4 エージェント結果の統合
    ├── workflow/              # Step Functions + workflow-starter Lambda
    ├── report-generator/      # HTML レポート生成
    ├── chatwork-notifier/     # Chatwork 通知
    └── observability/         # CloudWatch アラーム + SNS トピック
```
