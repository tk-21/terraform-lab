# aws-infra-review-ai

Terraform コードまたは AWS アーキテクチャ図を投入すると、4 つの専門 AI エージェントが並列でレビューし、supervisor が統合した最終レポートを生成する、マルチエージェント型インフラレビュー基盤です。

```text
あなた（TF コード or アーキテクチャ図）
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
  ├── security-reviewer    ── Bedrock Claude
  ├── cost-reviewer        ── Bedrock Claude
  ├── reliability-reviewer ── Bedrock Claude
  └── operations-reviewer  ── Bedrock Claude
  │
  ▼
supervisor（統合・トレードオフ解消）
  │
  ├── HTML レポート生成 → S3 保存
  └── Chatwork 通知（任意）
```

詳細な内部構成は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照してください。

---

## 目次

- [この README の使い方](#この-readme-の使い方)
- [最短ハンズオンの流れ](#最短ハンズオンの流れ)
- [前提条件](#前提条件)
- [ハンズオン 0: AWS 側の事前準備](#ハンズオン-0-aws-側の事前準備)
- [ハンズオン 1: リポジトリを準備する](#ハンズオン-1-リポジトリを準備する)
- [ハンズオン 2: Terraform 変数を設定する](#ハンズオン-2-terraform-変数を設定する)
- [ハンズオン 3: Terraform を初期化する](#ハンズオン-3-terraform-を初期化する)
- [ハンズオン 4: デプロイする](#ハンズオン-4-デプロイする)
- [ハンズオン 5: Terraform コードレビューを実行する](#ハンズオン-5-terraform-コードレビューを実行する)
- [ハンズオン 6: アーキテクチャ図レビューを実行する](#ハンズオン-6-アーキテクチャ図レビューを実行する)
- [ハンズオン 7: レビュー結果を確認する](#ハンズオン-7-レビュー結果を確認する)
- [任意設定: Chatwork 通知](#任意設定-chatwork-通知)
- [任意設定: CloudWatch アラーム通知](#任意設定-cloudwatch-アラーム通知)
- [任意設定: GitHub Actions CI/CD](#任意設定-github-actions-cicd)
- [API リファレンス](#api-リファレンス)
- [トラブルシューティング](#トラブルシューティング)
- [コスト目安](#コスト目安)
- [ディレクトリ構成](#ディレクトリ構成)

---

## この README の使い方

この README は「まず 1 回動かしてみる」ことを重視しています。

おすすめの読み方:

1. まずは [最短ハンズオンの流れ](#最短ハンズオンの流れ) で全体像を掴む
2. そのまま [ハンズオン 0](#ハンズオン-0-aws-側の事前準備) から順番に実行する
3. 動いた後に [API リファレンス](#api-リファレンス) や [任意設定](#任意設定-github-actions-cicd) を読む

---

## 最短ハンズオンの流れ

まず何をするプロジェクトなのかを最短で掴みたい場合は、この 8 ステップです。

1. AWS で Bedrock モデルアクセスを有効化する
2. Terraform backend 用の S3 バケットと DynamoDB テーブルを作る
3. `terraform.tfvars` を用意する
4. `environments/dev` で `terraform init`
5. `terraform plan`
6. あなた自身で `terraform apply` を実行する
7. `POST /reviews` でセッションを作り、S3 署名付き URL にファイルをアップロードする
8. `GET /reviews/{session_id}` で結果を確認する

想定所要時間:

- 初回セットアップを含めて 20〜40 分
- 1 回のレビュー実行はアップロード後 60〜90 秒程度

---

## 前提条件

| ツール | バージョン | 確認コマンド |
|---|---|---|
| Terraform | `>= 1.5.0` | `terraform version` |
| AWS CLI | `>= 2.0` | `aws --version` |
| `curl` | 任意 | `curl --version` |
| `jq` | 任意だが推奨 | `jq --version` |

作業リージョンは `ap-northeast-1`（東京）を前提としています。

事前に AWS CLI で認証済みであることを確認してください。

```bash
aws sts get-caller-identity
```

成功すれば、現在の AWS アカウント ID / ARN が返ります。

---

## ハンズオン 0: AWS 側の事前準備

### 0-1. Bedrock モデルアクセスを有効化する

このプロジェクトでは Bedrock の以下モデルを利用します。

- `anthropic.claude-3-5-sonnet-20241022-v2:0`

AWS コンソールで次を実施してください。

1. `Amazon Bedrock`
2. `モデルアクセス`
3. Anthropic Claude 3.5 Sonnet を申請・有効化
4. リージョンが `ap-northeast-1` であることを確認

これを忘れると、レビュー実行時に Bedrock 呼び出しが失敗します。

### 0-2. Terraform backend を作る

このリポジトリは `environments/dev/backend.tf` で、以下の backend 名を前提にしています。

- S3 bucket: `tfstate-aws-infra-review-ai`
- DynamoDB table: `tfstate-lock-aws-infra-review-ai`

初回だけ、次を実行してください。

```bash
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

もしすでに存在する場合は、そのまま次に進んで大丈夫です。

---

## ハンズオン 1: リポジトリを準備する

```bash
git clone https://github.com/your-org/aws-infra-review-ai.git
cd aws-infra-review-ai
```

この時点で、最低限次の構成が見えていれば OK です。

```text
environments/dev/
modules/
.github/workflows/
README.md
ARCHITECTURE.md
```

---

## ハンズオン 2: Terraform 変数を設定する

### 2-1. サンプルファイルをコピーする

```bash
cp environments/dev/terraform.tfvars.example environments/dev/terraform.tfvars
```

### 2-2. `terraform.tfvars` を編集する

最低限、最初のハンズオンでは以下で十分です。

```hcl
aws_region   = "ap-northeast-1"
environment  = "dev"
project_name = "aws-infra-review-ai"
owner        = "your-name"
cost_center  = "personal"
```

Chatwork やアラーム通知、GitHub Actions を使いたい場合は後から追記できます。

例:

```hcl
aws_region   = "ap-northeast-1"
environment  = "dev"
project_name = "aws-infra-review-ai"
owner        = "your-name"
cost_center  = "personal"

# 任意: Chatwork 通知
# chatwork_api_token = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# chatwork_room_id   = "123456789"

# 任意: CloudWatch アラーム通知
# alarm_email = "your-email@example.com"

# 任意: GitHub Actions OIDC
# github_repository = "your-org/aws-infra-review-ai"
```

### 2-3. 変数の意味

| 変数 | 必須 | 説明 |
|---|---|---|
| `aws_region` | 必須 | デプロイ先リージョン。基本は `ap-northeast-1` |
| `environment` | 必須 | 環境名。通常は `dev` |
| `project_name` | 必須 | リソース名のプレフィックス |
| `owner` | 必須 | タグ用の所有者名 |
| `cost_center` | 任意 | タグ用のコスト配賦名 |
| `chatwork_api_token` | 任意 | Chatwork 通知用トークン |
| `chatwork_room_id` | 任意 | Chatwork 通知先ルーム ID |
| `alarm_email` | 任意 | CloudWatch アラームのメール通知先 |
| `github_repository` | 任意 | GitHub Actions OIDC 用の `org/repo` |

---

## ハンズオン 3: Terraform を初期化する

```bash
cd environments/dev
terraform init
```

成功すると、provider と backend の初期化が走ります。

続けて、設定に問題がないか軽く確認しておくと安心です。

```bash
terraform validate
terraform fmt -check -recursive
```

---

## ハンズオン 4: デプロイする

### 4-1. まずは plan を確認する

```bash
terraform plan
```

ここで以下を確認します。

- 想定どおり `dev` 環境のリソースが作られるか
- 失敗していないか
- 変数の typo がないか

### 4-2. apply を実行する

このプロジェクトでは **Terraform の実行はユーザー自身が行う** 前提です。  
内容を確認したうえで、あなた自身で次を実行してください。

```bash
terraform apply
```

所要時間の目安は 2〜3 分程度です。

### 4-3. 出力値を確認する

apply 後に、まず次を実行してください。

```bash
terraform output
```

特によく使う出力値:

| 出力名 | 使い道 |
|---|---|
| `api_endpoint` | API 呼び出しの入口 |
| `input_bucket_id` | 入力ファイル保存先 S3 |
| `reports_bucket_id` | HTML レポート保存先 S3 |
| `review_table_name` | セッション状態確認用 DynamoDB |
| `state_machine_arn` | Step Functions 実行確認 |
| `chatwork_token_ssm_path` | Chatwork トークン登録先 |
| `alarm_sns_topic_arn` | アラーム通知先 SNS |

よく使う値をシェル変数に入れておくと後が楽です。

```bash
API_ENDPOINT=$(terraform output -raw api_endpoint)
TABLE_NAME=$(terraform output -raw review_table_name)
STATE_MACHINE_ARN=$(terraform output -raw state_machine_arn)
```

---

## ハンズオン 5: Terraform コードレビューを実行する

ここでは、最も基本的なハンズオンとして Terraform ファイルを 1 つレビューさせます。

### 5-1. レビュー対象ファイルを用意する

例として、このリポジトリ自身の Terraform を使ってもよいです。

```bash
cd /home/takuya/terraform-lab/aws-infra-review-ai
TARGET_FILE="environments/dev/main.tf"
```

別の Terraform ファイルをレビューしたい場合は、`TARGET_FILE` を差し替えてください。

### 5-2. レビューセッションを作成する

```bash
cd environments/dev
API_ENDPOINT=$(terraform output -raw api_endpoint)

RESPONSE=$(curl -s -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "input_type": "terraform",
    "filename": "main.tf"
  }')

echo "$RESPONSE" | jq .
```

成功例:

```json
{
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "upload_url": "https://...s3.amazonaws.com/reviews/a1b2.../main.tf?...",
  "s3_key": "reviews/a1b2c3d4-e5f6-7890-abcd-ef1234567890/main.tf",
  "status": "pending",
  "message": "upload_url に main.tf をアップロードしてください。..."
}
```

### 5-3. レスポンスから値を取り出す

```bash
SESSION_ID=$(echo "$RESPONSE" | jq -r '.session_id')
UPLOAD_URL=$(echo "$RESPONSE" | jq -r '.upload_url')
```

### 5-4. ファイルをアップロードする

プロジェクトルートに戻ってから、対象ファイルを PUT します。

```bash
cd /home/takuya/terraform-lab/aws-infra-review-ai

curl -X PUT "$UPLOAD_URL" \
  --upload-file "$TARGET_FILE"

echo "レビュー開始: SESSION_ID=$SESSION_ID"
```

このアップロードをきっかけに、内部では以下が自動で動きます。

1. S3 イベント発火
2. `workflow-starter` Lambda 起動
3. Step Functions 開始
4. 4 reviewer の並列実行
5. supervisor 統合
6. HTML レポート生成

### 5-5. 進捗を確認する

```bash
cd environments/dev
curl -s "$API_ENDPOINT/$SESSION_ID" | jq .
```

レビュー中の例:

```json
{
  "session_id": "a1b2c3d4-...",
  "status": "running",
  "input_type": "terraform",
  "created_at": "2026-05-06T12:00:00+00:00"
}
```

完了まで 60〜90 秒ほど待って、再度同じコマンドを実行してください。

### 5-6. 完了結果を確認する

完了すると、次のような JSON が返ります。

```json
{
  "session_id": "a1b2c3d4-...",
  "status": "completed",
  "input_type": "terraform",
  "created_at": "2026-05-06T12:00:00+00:00",
  "scores": {
    "security": 72,
    "cost": 85,
    "reliability": 60,
    "operations": 78,
    "total": 72
  },
  "executive_summary": "全体的にセキュリティと可用性に改善余地があります。",
  "priority_actions": [
    {
      "rank": 1,
      "action": "IAM ポリシーの権限を絞り込む",
      "source_agent": "security",
      "severity": "HIGH"
    }
  ],
  "final_report_url": "https://..."
}
```

`final_report_url` をブラウザで開くと、整形済みの HTML レポートを確認できます。

---

## ハンズオン 6: アーキテクチャ図レビューを実行する

画像や PDF のアーキテクチャ図も同じ流れでレビューできます。  
違いは `input_type` を `architecture` にすることだけです。

### 6-1. 対応形式

| 形式 | 拡張子 | 最大サイズ |
|---|---|---|
| 画像 | `.png` `.jpg` `.jpeg` `.webp` `.gif` | 3 MB |
| PDF | `.pdf` | 3 MB |
| テキスト | `.tf` `.json` `.yaml` `.txt` など | 100 KB |

### 6-2. セッションを作る

```bash
cd environments/dev

RESPONSE=$(curl -s -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "input_type": "architecture",
    "filename": "architecture.png"
  }')

echo "$RESPONSE" | jq .
```

### 6-3. 画像をアップロードする

```bash
SESSION_ID=$(echo "$RESPONSE" | jq -r '.session_id')
UPLOAD_URL=$(echo "$RESPONSE" | jq -r '.upload_url')

curl -X PUT "$UPLOAD_URL" \
  --upload-file /path/to/architecture.png
```

### 6-4. 進捗と完了を確認する

```bash
curl -s "$API_ENDPOINT/$SESSION_ID" | jq .
```

内部では `workflow-starter` が Bedrock Vision / Document API を使って図をテキスト化してから、reviewer 群に渡します。

---

## ハンズオン 7: レビュー結果を確認する

### 7-1. API で確認する

最も簡単なのは API です。

```bash
curl -s "$API_ENDPOINT/$SESSION_ID" | jq .
```

### 7-2. DynamoDB で確認する

```bash
cd environments/dev
TABLE_NAME=$(terraform output -raw review_table_name)

aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"session_id\": {\"S\": \"$SESSION_ID\"}}" \
  --region ap-northeast-1 \
  | jq .
```

ステータスだけを見たい場合:

```bash
aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"session_id\": {\"S\": \"$SESSION_ID\"}}" \
  --region ap-northeast-1 \
  | jq -r '.Item.status.S'
```

### 7-3. Step Functions 実行履歴を確認する

```bash
cd environments/dev
STATE_MACHINE_ARN=$(terraform output -raw state_machine_arn)

aws stepfunctions list-executions \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --region ap-northeast-1 \
  | jq '.executions[] | {name, status, startDate, stopDate}'
```

### 7-4. HTML レポート URL を確認する

```bash
REPORT_URL=$(aws dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"session_id\": {\"S\": \"$SESSION_ID\"}}" \
  --region ap-northeast-1 \
  | jq -r '.Item.final_report_url.S')

echo "$REPORT_URL"
```

この URL は 7 日間有効です。

### 7-5. ステータスの意味

| ステータス | 説明 |
|---|---|
| `pending` | セッション作成済み、まだファイル未アップロード |
| `starting` | `workflow-starter` が起動処理中 |
| `running` | Step Functions と reviewer が実行中 |
| `completed` | レビュー・レポート生成まで完了 |
| `failed` | どこかの処理で失敗 |

---

## 任意設定: Chatwork 通知

Chatwork 通知を使わなくても、レビュー自体は最後まで完了します。  
通知が欲しい場合のみ設定してください。

### 1. `terraform.tfvars` に room ID を書く

```hcl
chatwork_room_id = "123456789"
```

### 2. apply 後に SSM Parameter Store にトークンを登録する

```bash
cd environments/dev
CHATWORK_TOKEN_SSM_PATH=$(terraform output -raw chatwork_token_ssm_path)

aws ssm put-parameter \
  --name "$CHATWORK_TOKEN_SSM_PATH" \
  --value "YOUR_CHATWORK_API_TOKEN" \
  --type SecureString \
  --overwrite \
  --region ap-northeast-1
```

### 3. 動作確認

レビューを 1 回実行すると、完了後に Chatwork へ通知されます。

通知されない場合は次を確認してください。

```bash
aws logs tail "/aws/lambda/aws-infra-review-ai-chatwork-notifier-dev" \
  --since 5m \
  --region ap-northeast-1
```

---

## 任意設定: CloudWatch アラーム通知

### 1. `terraform.tfvars` にメールアドレスを書く

```hcl
alarm_email = "your-email@example.com"
```

### 2. あなた自身で再度 apply する

```bash
cd environments/dev
terraform plan
terraform apply
```

### 3. AWS から届く確認メールを承認する

SNS の Email subscription は、承認しないと通知が届きません。

### 4. アラーム状態を確認する

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "aws-infra-review-ai" \
  --region ap-northeast-1 \
  | jq '.MetricAlarms[] | {name: .AlarmName, state: .StateValue}'
```

作成されるアラーム:

- Step Functions 実行失敗
- Step Functions タイムアウト
- `workflow-starter` Lambda エラー
- `supervisor` Lambda エラー

---

## 任意設定: GitHub Actions CI/CD

このリポジトリには OIDC ベースの GitHub Actions CI/CD が含まれています。

### 1. `terraform.tfvars` に GitHub リポジトリを設定する

```hcl
github_repository = "your-org/aws-infra-review-ai"
```

### 2. OIDC 関連リソースをあなた自身で apply する

```bash
cd environments/dev

terraform apply \
  -target=aws_iam_openid_connect_provider.github \
  -target=aws_iam_role.github_actions \
  -target=aws_iam_role_policy.github_actions_terraform
```

### 3. ロール ARN を確認する

```bash
terraform output github_actions_role_arn
```

### 4. GitHub Secrets を設定する

GitHub の `Settings -> Secrets and variables -> Actions` に以下を設定します。

| Secret 名 | 必須 | 値 |
|---|---|---|
| `TF_ROLE_ARN` | 必須 | `terraform output github_actions_role_arn` の出力 |
| `CHATWORK_API_TOKEN` | 任意 | Chatwork API トークン |
| `CHATWORK_ROOM_ID` | 任意 | Chatwork ルーム ID |

### 5. CI の動作確認

```bash
git checkout -b feature/test-ci
echo "# test" >> modules/storage/main.tf
git add -A
git commit -m "test: verify terraform ci"
git push origin feature/test-ci
```

PR を作成すると `terraform plan` が実行され、結果が PR コメントに投稿されます。

---

## API リファレンス

### エンドポイント一覧

| メソッド | パス | 説明 |
|---|---|---|
| `POST` | `/reviews` | レビューセッション作成 + S3 アップロード URL 発行 |
| `GET` | `/reviews/{session_id}` | セッション状態・結果取得 |

### POST `/reviews`

リクエスト:

```json
{
  "input_type": "terraform",
  "filename": "main.tf"
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `input_type` | string | 必須 | `terraform` または `architecture` |
| `filename` | string | 任意 | アップロード対象ファイル名 |

レスポンス例:

```json
{
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "upload_url": "https://...s3...?...",
  "s3_key": "reviews/a1b2c3d4-.../main.tf",
  "status": "pending",
  "message": "upload_url に main.tf をアップロードしてください。..."
}
```

### GET `/reviews/{session_id}`

レスポンス共通項目:

| フィールド | 説明 |
|---|---|
| `session_id` | セッション ID |
| `status` | `pending` / `starting` / `running` / `completed` / `failed` |
| `input_type` | `terraform` / `architecture` |
| `created_at` | セッション作成日時 |

`completed` 時のみ返る項目:

| フィールド | 説明 |
|---|---|
| `scores` | 各 reviewer と総合スコア |
| `executive_summary` | 統合サマリー |
| `priority_actions` | 優先対応アクション |
| `final_report_url` | HTML レポート署名付き URL |

---

## トラブルシューティング

### レビューが `failed` になる

Step Functions の失敗イベントを確認します。

```bash
aws stepfunctions get-execution-history \
  --execution-arn "arn:aws:states:ap-northeast-1:ACCOUNT_ID:execution:aws-infra-review-ai-review-workflow-dev:review-SESSION_ID" \
  --region ap-northeast-1 \
  | jq '.events[] | select(.type | contains("Failed"))'
```

よくある原因:

- Bedrock モデルアクセス未有効化
- Lambda タイムアウト
- IAM 権限不足
- 画像/PDF が 3MB を超過
- テキスト入力が大きすぎる

### S3 アップロード後にワークフローが起動しない

```bash
aws logs tail "/aws/lambda/aws-infra-review-ai-workflow-starter-dev" \
  --since 5m \
  --region ap-northeast-1
```

確認ポイント:

- セッションが `pending` のままだったか
- `reviews/` プレフィックス配下にアップロードしたか
- 同じ `session_id` に再アップロードしていないか

### Chatwork に通知が届かない

```bash
aws logs tail "/aws/lambda/aws-infra-review-ai-chatwork-notifier-dev" \
  --since 5m \
  --region ap-northeast-1

aws ssm get-parameter \
  --name "/aws-infra-review-ai/dev/chatwork/api_token" \
  --with-decryption \
  --region ap-northeast-1 \
  | jq '.Parameter.Value'
```

注意:

- Chatwork 通知失敗でもワークフロー全体は `completed` になります

### `terraform plan` が認証エラーになる

```bash
aws sts get-caller-identity
```

GitHub Actions 側なら、`TF_ROLE_ARN` の設定も確認してください。

---

## コスト目安

1 回のレビュー実行あたりの概算です。

| サービス | 用途 | 概算コスト |
|---|---|---|
| Bedrock Claude 3.5 Sonnet | 4 reviewer + supervisor | 約 `$0.09` |
| Bedrock Claude 3.5 Sonnet | 画像前処理 | 約 `$0.02` |
| Step Functions | Workflow 実行 | 約 `$0.001` |
| Lambda | 各処理実行 | 約 `$0.001` |
| S3 | 入力ファイル・HTML レポート | 約 `$0.001` |
| DynamoDB | セッション保存 | 約 `$0.001` |

合計:

- Terraform コードレビュー: 約 `$0.09`
- 画像レビュー: 約 `$0.09〜0.12`

---

## ディレクトリ構成

```text
aws-infra-review-ai/
├── .github/workflows/
│   └── terraform.yml          # OIDC + plan/apply
├── environments/
│   └── dev/
│       ├── backend.tf         # S3 remote state
│       ├── github-actions.tf  # OIDC provider + IAM role
│       ├── main.tf            # 全 module の配線
│       ├── outputs.tf
│       ├── terraform.tfvars
│       ├── terraform.tfvars.example
│       └── variables.tf
├── modules/
│   ├── storage/
│   ├── api/
│   ├── workflow/
│   ├── agents/
│   │   ├── security-reviewer/
│   │   ├── cost-reviewer/
│   │   ├── reliability-reviewer/
│   │   ├── operations-reviewer/
│   │   └── supervisor/
│   ├── report-generator/
│   ├── chatwork-notifier/
│   └── observability/
├── ARCHITECTURE.md
└── README.md
```

---

## ここまで終わったら

この README のハンズオンを完了すると、少なくとも次ができる状態になります。

1. AWS 上にレビュー基盤をデプロイできる
2. Terraform ファイルをレビューできる
3. アーキテクチャ図をレビューできる
4. Step Functions / DynamoDB / HTML レポートで結果を追える

内部構造まで深く理解したくなったら、次に [ARCHITECTURE.md](./ARCHITECTURE.md) を読むのがおすすめです。
