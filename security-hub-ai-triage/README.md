# security-hub-ai-triage

Security Hub の検出結果を EventBridge で受け取り、Amazon Bedrock（Claude Haiku）で自動トリアージし、Chatwork へ日本語通知するシステムです。

## アーキテクチャ

```
Security Hub
    |
    | (Findings - Imported)
    v
EventBridge Rule
    |
    | (CRITICAL / HIGH / MEDIUM / LOW)
    v
Lambda (triage-handler)
    |
    +---> DynamoDB (重複排除チェック)
    |
    +---> Bedrock (Claude Haiku) ---> AI トリアージ (即対応 / 監視継続 / 無視可能)
    |
    +---> Chatwork (CRITICAL / HIGH のみ通知)
    |
    +---> S3 (全件フルレポート保存)
    |
    +---> DynamoDB (処理済みとして記録 / TTL: 7日)
```

## 前提条件

以下のツール・設定が完了していることを確認してください。

```bash
# AWS CLI バージョン確認（2.x 推奨）
aws --version

# Terraform バージョン確認（>= 1.7 必須）
terraform version

# Python バージョン確認（3.12 推奨）
python3 --version

# AWS 認証情報の確認
aws sts get-caller-identity
```

また、以下の事前準備が必要です。

- AWS アカウントへの管理者権限（初回リソース作成のため）
- AWS Security Hub が対象アカウントで有効化済み
- Chatwork アカウントと API トークン（Chatwork > 設定 > API トークン から取得）
- Bedrock で `anthropic.claude-haiku-4-5` モデルへのアクセス許可

---

## セットアップ手順

### ステップ 1: Bedrock モデルアクセスの有効化

AWS コンソール、または CLI でモデルアクセスを許可します。

```bash
# AWS コンソールで設定する場合:
# Amazon Bedrock > Model access > Manage model access
# > Anthropic > Claude Haiku にチェック > Save changes

# CLI で現在のアクセス状況を確認する場合:
aws bedrock list-foundation-models \
  --region ap-northeast-1 \
  --query "modelSummaries[?modelId=='anthropic.claude-haiku-4-5-20251001-v1:0']"
```

### ステップ 2: Chatwork トークンを Secrets Manager に登録

```bash
# シークレットの作成（YOUR_CHATWORK_API_TOKEN を実際のトークンに置き換え）
aws secretsmanager create-secret \
  --name chatwork-token \
  --secret-string '{"token":"YOUR_CHATWORK_API_TOKEN"}' \
  --region ap-northeast-1

# 作成されたシークレットの ARN を確認（後の手順で使用）
aws secretsmanager describe-secret \
  --secret-id chatwork-token \
  --region ap-northeast-1 \
  --query "ARN" \
  --output text
```

出力された ARN（例: `arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:chatwork-token-AbCdEf`）を控えておきます。

### ステップ 3: Chatwork ルーム ID の確認

通知先のルーム ID を確認します。Chatwork の URL が `https://www.chatwork.com/#!ridXXXXXXXXX` の場合、`XXXXXXXXX` がルーム ID です。

### ステップ 4: GitHub Actions 用 OIDC ロールの設定

GitHub Actions から OIDC で AWS 認証するための IAM ロールを作成し、ARN を GitHub Secrets に登録してください。

```
リポジトリ > Settings > Secrets and variables > Actions > New repository secret

  AWS_ROLE_ARN        = arn:aws:iam::123456789012:role/github-actions-role
  CHATWORK_SECRET_ARN = arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:chatwork-token-AbCdEf
  CHATWORK_ROOM_ID    = 123456789
```

OIDC ロールを作成する IAM ポリシーの例:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
        }
      }
    }
  ]
}
```

### ステップ 5: Terraform 変数ファイルの作成

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を編集して実際の値を入力します:

```hcl
project_name        = "security-hub-ai-triage"
environment         = "dev"
aws_region          = "ap-northeast-1"
chatwork_secret_arn = "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:chatwork-token-AbCdEf"
chatwork_room_id    = "123456789"
```

> **注意**: `terraform.tfvars` は `.gitignore` に含まれているため、Git にコミットされません。

### ステップ 6: Terraform の実行

```bash
cd terraform

# 初期化（プロバイダーとモジュールをダウンロード）
terraform init

# フォーマット確認
terraform fmt -check -recursive

# 検証
terraform validate

# Lambda ZIP のビルド（terraform apply 前に必要）
cd ../lambda/triage_handler
pip install -r requirements.txt -t ./package
cd package && zip -r ../triage_handler.zip . && cd ..
zip -g triage_handler.zip *.py
cd ../../terraform

# プラン確認（変数ファイルを使用する場合）
terraform plan \
  -var-file=terraform.tfvars

# または変数をコマンドラインで指定する場合
terraform plan \
  -var="chatwork_secret_arn=arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:chatwork-token-AbCdEf" \
  -var="chatwork_room_id=YOUR_ROOM_ID"

# デプロイ
terraform apply \
  -var-file=terraform.tfvars \
  -auto-approve
```

デプロイ完了後、以下のリソースが作成されます:

- Lambda 関数: `security-hub-ai-triage-triage-handler-dev`
- DynamoDB テーブル: `security-hub-ai-triage-dedup-dev`
- S3 バケット: `security-hub-ai-triage-reports-{ACCOUNT_ID}`
- EventBridge ルール: `security-hub-ai-triage-findings-dev`
- IAM ロール: `security-hub-ai-triage-lambda-role-dev`

---

## デプロイ後の確認

### 作成リソースの確認

```bash
# Lambda 関数の確認
aws lambda get-function \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --region ap-northeast-1

# DynamoDB テーブルの確認
aws dynamodb describe-table \
  --table-name security-hub-ai-triage-dedup-dev \
  --region ap-northeast-1 \
  --query "Table.{Status:TableStatus,TTL:TimeToLiveDescription}"

# S3 バケットの確認
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 ls s3://security-hub-ai-triage-reports-${ACCOUNT_ID}/

# EventBridge ルールの確認
aws events describe-rule \
  --name security-hub-ai-triage-findings-dev \
  --region ap-northeast-1 \
  --query "{State:State,EventPattern:EventPattern}"
```

---

## 動作確認方法

### 方法 1: Lambda を直接テスト実行

サンプルイベントファイルを使って Lambda を直接呼び出します。

```bash
# テスト用イベントファイルを作成
cat > /tmp/test_event.json << 'EOF'
{
  "source": "aws.securityhub",
  "detail-type": "Security Hub Findings - Imported",
  "detail": {
    "findings": [
      {
        "SchemaVersion": "2018-10-08",
        "Id": "arn:aws:securityhub:ap-northeast-1:123456789012:finding/test-finding-001",
        "ProductArn": "arn:aws:securityhub:ap-northeast-1:123456789012:product/123456789012/default",
        "GeneratorId": "test-generator",
        "AwsAccountId": "123456789012",
        "Types": ["Software and Configuration Checks"],
        "CreatedAt": "2025-08-01T00:00:00Z",
        "UpdatedAt": "2025-08-01T00:00:00Z",
        "Severity": {"Label": "HIGH", "Normalized": 70},
        "Title": "テスト: S3 バケットがパブリックに公開されています",
        "Description": "S3 バケット my-test-bucket がインターネットに公開されています。",
        "Resources": [
          {
            "Type": "AwsS3Bucket",
            "Id": "arn:aws:s3:::my-test-bucket",
            "Region": "ap-northeast-1"
          }
        ]
      }
    ]
  }
}
EOF

# Lambda を直接実行
aws lambda invoke \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --payload file:///tmp/test_event.json \
  --cli-binary-format raw-in-base64-out \
  --region ap-northeast-1 \
  /tmp/response.json

# 実行結果を確認
cat /tmp/response.json | python3 -m json.tool
```

期待されるレスポンス例:

```json
{
  "processed": 1,
  "skipped": 0,
  "notified": 1
}
```

### 方法 2: Security Hub テスト Finding を生成

実際に Security Hub へ Finding を投入して、EventBridge 経由でのエンドツーエンド動作を確認します。

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws securityhub batch-import-findings --findings "[
  {
    \"SchemaVersion\": \"2018-10-08\",
    \"Id\": \"arn:aws:securityhub:ap-northeast-1:${ACCOUNT_ID}:finding/test-finding-e2e-001\",
    \"ProductArn\": \"arn:aws:securityhub:ap-northeast-1:${ACCOUNT_ID}:product/${ACCOUNT_ID}/default\",
    \"GeneratorId\": \"test-generator\",
    \"AwsAccountId\": \"${ACCOUNT_ID}\",
    \"Types\": [\"Software and Configuration Checks\"],
    \"CreatedAt\": \"2025-08-01T00:00:00Z\",
    \"UpdatedAt\": \"2025-08-01T00:00:00Z\",
    \"Severity\": {\"Label\": \"HIGH\", \"Normalized\": 70},
    \"Title\": \"テスト: IAM ユーザーに MFA が設定されていません\",
    \"Description\": \"IAM ユーザー test-user に MFA が設定されておらず、セキュリティリスクがあります。\",
    \"Resources\": [
      {
        \"Type\": \"AwsIamUser\",
        \"Id\": \"arn:aws:iam::${ACCOUNT_ID}:user/test-user\",
        \"Region\": \"ap-northeast-1\"
      }
    ]
  }
]" --region ap-northeast-1
```

### 動作確認: CloudWatch Logs の確認

```bash
# 最新のログストリームを確認
LOG_GROUP="/aws/lambda/security-hub-ai-triage-triage-handler-dev"

aws logs describe-log-streams \
  --log-group-name "${LOG_GROUP}" \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --region ap-northeast-1 \
  --query "logStreams[0].logStreamName" \
  --output text

# 最新のログを表示（LOG_STREAM_NAME は上記コマンドの出力に置き換え）
aws logs get-log-events \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name "LOG_STREAM_NAME" \
  --region ap-northeast-1 \
  --query "events[*].message" \
  --output text
```

### 動作確認: S3 にレポートが保存されているか確認

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="security-hub-ai-triage-reports-${ACCOUNT_ID}"
TODAY=$(date +%Y/%m/%d)

# 本日分のレポートを一覧表示
aws s3 ls "s3://${BUCKET}/findings/${TODAY}/"

# レポートの内容を表示（KEY を実際のオブジェクトキーに置き換え）
aws s3 cp "s3://${BUCKET}/findings/${TODAY}/KEY" - | python3 -m json.tool
```

### 動作確認: DynamoDB の重複排除レコードを確認

```bash
# テーブルのレコードをスキャン（確認用）
aws dynamodb scan \
  --table-name security-hub-ai-triage-dedup-dev \
  --region ap-northeast-1 \
  --query "Items[*].{finding_id:finding_id.S,verdict:verdict.S,processed_at:processed_at.S}"
```

---

## GitHub Actions による自動デプロイ

リポジトリへのプッシュ・PR で自動的に Terraform が実行されます。

| イベント | 実行内容 |
|---------|---------|
| Pull Request | `fmt -check` / `validate` / `plan` の実行 + PR にプラン結果をコメント |
| main へのマージ | 上記 + `apply` の実行（自動デプロイ）|

ワークフローの実行状況は GitHub リポジトリの `Actions` タブで確認できます。

---

## コスト目安

| サービス | 概算コスト（月） |
|---------|----------------|
| Lambda | ~$0（無料枠内） |
| Bedrock (Claude Haiku) | $0.25 / 100万トークン（入力）|
| DynamoDB | ~$0（PAY_PER_REQUEST、少量） |
| S3 | ~$0.023 / GB |
| EventBridge | $1 / 100万イベント |

**月間 1,000 件の Findings を処理した場合の概算: $0.10〜$0.50**

---

## クリーンアップ

検証が完了したら、不要なコストを避けるためにリソースを削除してください。

### 1. Security Hub の無効化

```bash
# Security Hub を無効化（継続的にコストが発生するため必須）
aws securityhub disable-security-hub --region ap-northeast-1

# 無効化の確認
aws securityhub describe-hub --region ap-northeast-1
```

### 2. Terraform リソースの削除

```bash
cd terraform

terraform destroy \
  -var-file=terraform.tfvars \
  -auto-approve
```

### 3. Secrets Manager のシークレット削除

```bash
# シークレットの削除（--force-delete-without-recovery は即時削除）
aws secretsmanager delete-secret \
  --secret-id chatwork-token \
  --force-delete-without-recovery \
  --region ap-northeast-1
```

---

## トラブルシューティング

### Lambda がタイムアウトする

Bedrock の呼び出しに時間がかかっている可能性があります。CloudWatch Logs でエラーを確認し、必要に応じてタイムアウト値を変更してください。

```bash
# タイムアウト設定の確認
aws lambda get-function-configuration \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --region ap-northeast-1 \
  --query "Timeout"
```

### Chatwork 通知が届かない

```bash
# Lambda のログでエラーを確認
aws logs filter-log-events \
  --log-group-name "/aws/lambda/security-hub-ai-triage-triage-handler-dev" \
  --filter-pattern "Chatwork" \
  --region ap-northeast-1 \
  --query "events[*].message" \
  --output text

# Secrets Manager のシークレット値を確認
aws secretsmanager get-secret-value \
  --secret-id chatwork-token \
  --region ap-northeast-1 \
  --query "SecretString"
```

### Bedrock へのアクセスが拒否される

```bash
# IAM ロールのポリシーを確認
ROLE_NAME="security-hub-ai-triage-lambda-role-dev"
aws iam list-role-policies --role-name "${ROLE_NAME}"
aws iam get-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "security-hub-ai-triage-lambda-policy-dev"

# Bedrock モデルアクセスを確認
aws bedrock list-foundation-models \
  --region ap-northeast-1 \
  --query "modelSummaries[?contains(modelId,'haiku')].[modelId,modelLifecycle.status]"
```

### EventBridge ルールが Lambda を起動しない

```bash
# ルールの状態確認
aws events describe-rule \
  --name security-hub-ai-triage-findings-dev \
  --region ap-northeast-1

# Lambda への呼び出し権限を確認
aws lambda get-policy \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --region ap-northeast-1
```

---

## 注意事項

> **重要**: AWS Security Hub は有効化すると継続的にコストが発生します。
> 検証が完了したら必ず無効化してください。

- Security Hub の料金: $0.001〜$0.0001 / Finding（数量によって異なる）
- 無効化せず放置すると、毎月数十〜数百ドルのコストが発生する可能性があります
- 本番環境では Security Hub の有効化は常時必須ですが、検証環境では使用後に無効化を検討してください
- `terraform.tfvars` には機密情報が含まれるため、Git にコミットしないよう注意してください（`.gitignore` で除外済み）
