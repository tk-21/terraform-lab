# security-hub-ai-triage

Security Hub の Findings を EventBridge で受け取り、Amazon Bedrock で自動トリアージし、重要なものだけを Chatwork に通知しつつ、全件を S3 に保存するサーバレスシステムです。

詳細な構成理解は [ARCHITECTURE.md](/home/takuya/terraform-lab/security-hub-ai-triage/ARCHITECTURE.md) を参照してください。  
この README は「このプロジェクトを実際にハンズオンで動かす」ことに特化しています。

## このハンズオンで得られること

- Security Hub の Finding をイベント駆動で処理する流れを理解できる
- EventBridge、Lambda、DynamoDB、S3、Bedrock を組み合わせた実践的なサーバレス構成を体験できる
- Bedrock を使ったセキュリティ運用の自動トリアージの基本パターンを学べる
- Secrets Manager を使った外部通知トークンの安全な扱い方を確認できる
- Terraform でセキュリティ運用基盤を構築する手順を一通りなぞれる
- Chatwork 通知、S3 保存、DynamoDB 重複排除まで含めた E2E の確認方法を身につけられる

## できること

- Security Hub の Finding を自動受信
- Bedrock で日本語トリアージ
- `CRITICAL` / `HIGH` のみ Chatwork 通知
- 全件を S3 に JSON 保存
- DynamoDB で 7 日間の重複排除

## 全体像

```text
Security Hub
  -> EventBridge Rule
  -> Lambda (triage-handler)
     -> DynamoDB で重複チェック
     -> Bedrock で AI トリアージ
     -> Chatwork に通知（CRITICAL/HIGH のみ）
     -> S3 にフルレポート保存
     -> DynamoDB に処理済み記録
```

## この README の進め方

このハンズオンは次の順で進めます。

1. ローカル環境を確認する
2. Bedrock / Security Hub / Chatwork の前提を準備する
3. Secrets Manager に Chatwork トークンを登録する
4. Terraform 変数を設定する
5. Terraform でリソースを作成する
6. Lambda を直接呼んで動作確認する
7. Security Hub にテスト Finding を投入して E2E 確認する
8. CloudWatch Logs / S3 / DynamoDB を確認する
9. 不要になったらクリーンアップする

---

## 前提条件

以下を利用できることを確認してください。

- AWS CLI
- Terraform `~> 1.7`
- Python 3.12 以上
- `zip`
- Chatwork の API トークン
- Bedrock の対象モデル利用権限

### AWS 側の前提

- 作業リージョンは `ap-northeast-1`
- Security Hub が有効化済み
- Bedrock で `anthropic.claude-haiku-4-5` を利用可能
- Secrets Manager を使える権限がある
- Terraform で IAM / Lambda / EventBridge / DynamoDB / S3 を作成できる

### ローカル確認コマンド

```bash
aws --version
terraform version
python3 --version
zip -v
aws sts get-caller-identity
```

---

## 事前に知っておくこと

- このプロジェクトでは Python を使う作業は `.venv` 前提です
- Terraform の `apply` / `destroy` は README では紹介しますが、実行はユーザー自身が行ってください
- Bedrock や Security Hub の利用には継続コストが発生する可能性があります
- `terraform.tfvars` には機密情報が入るため Git にコミットしません

---

## ステップ 1: プロジェクトルートと `.venv` を準備する

まずプロジェクトルートにいることを確認します。

```bash
cd /home/takuya/terraform-lab/security-hub-ai-triage
pwd
```

`.venv` がなければ作成します。

```bash
python3 -m venv .venv
```

有効化して、以後の Python 系作業はこの仮想環境を使います。

```bash
source .venv/bin/activate
which python
```

`which python` の出力が `.venv/bin/python` になっていれば OK です。

---

## ステップ 2: Bedrock モデルアクセスを確認する

このシステムはデフォルトで `anthropic.claude-haiku-4-5` を使います。  
AWS コンソールの `Amazon Bedrock > Model access` で対象モデルが利用可能か確認してください。

CLI で存在確認する例:

```bash
aws bedrock list-foundation-models \
  --region ap-northeast-1 \
  --query "modelSummaries[?contains(modelId, 'claude-haiku-4-5')].[modelId]"
```

結果にモデル ID が返れば確認完了です。

---

## ステップ 3: Security Hub を確認する

Security Hub が有効でないと EventBridge 経由で Finding が流れてきません。

```bash
aws securityhub describe-hub --region ap-northeast-1
```

まだ有効化していない場合は、コンソールから有効化するか、必要に応じて CLI で有効化してください。

```bash
aws securityhub enable-security-hub --region ap-northeast-1
```

---

## ステップ 4: Chatwork トークンとルーム ID を用意する

### 4-1. Chatwork API トークンを取得する

Chatwork の UI から API トークンを取得します。

- Chatwork にログイン
- `設定`
- `APIトークン`
- トークンを発行または確認

### 4-2. 通知先ルーム ID を確認する

Chatwork のルーム URL が次の形式なら、`rid` の後ろがルーム ID です。

```text
https://www.chatwork.com/#!rid123456789
```

この例ではルーム ID は `123456789` です。

---

## ステップ 5: Secrets Manager に Chatwork トークンを登録する

Chatwork トークンは Lambda 環境変数に直接書かず、Secrets Manager から取得します。

```bash
aws secretsmanager create-secret \
  --name chatwork-token \
  --secret-string '{"token":"YOUR_CHATWORK_API_TOKEN"}' \
  --region ap-northeast-1
```

すでに存在する場合は更新します。

```bash
aws secretsmanager put-secret-value \
  --secret-id chatwork-token \
  --secret-string '{"token":"YOUR_CHATWORK_API_TOKEN"}' \
  --region ap-northeast-1
```

ARN を取得して控えます。

```bash
aws secretsmanager describe-secret \
  --secret-id chatwork-token \
  --region ap-northeast-1 \
  --query "ARN" \
  --output text
```

例:

```text
arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:chatwork-token-AbCdEf
```

---

## ステップ 6: Terraform 変数ファイルを作成する

サンプルファイルをコピーします。

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を次のように編集します。

```hcl
project_name        = "security-hub-ai-triage"
environment         = "dev"
aws_region          = "ap-northeast-1"
chatwork_secret_arn = "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:chatwork-token-AbCdEf"
chatwork_room_id    = "123456789"
bedrock_model_id    = "anthropic.claude-haiku-4-5"
```

各値の意味:

- `project_name`: 作成されるリソース名のプレフィックス
- `environment`: `dev` / `stg` / `prod` など
- `aws_region`: デプロイ先リージョン
- `chatwork_secret_arn`: 先ほど作成したシークレットの ARN
- `chatwork_room_id`: 通知先の Chatwork ルーム ID
- `bedrock_model_id`: Lambda が呼ぶ Bedrock モデル ID

---

## ステップ 7: Terraform 実行前に内容を確認する

このプロジェクトでは次の AWS リソースが作成されます。

- Lambda 関数
- IAM ロールとインラインポリシー
- EventBridge ルール
- DynamoDB テーブル
- S3 バケット

主な名前例:

- Lambda: `security-hub-ai-triage-triage-handler-dev`
- DynamoDB: `security-hub-ai-triage-dedup-dev`
- EventBridge Rule: `security-hub-ai-triage-findings-rule-dev`
- IAM Role: `security-hub-ai-triage-lambda-role-dev`
- S3: `security-hub-ai-triage-reports-<ACCOUNT_ID>`

---

## ステップ 8: Terraform を実行する

まず `terraform/` ディレクトリに移動します。

```bash
cd /home/takuya/terraform-lab/security-hub-ai-triage/terraform
```

初期化します。

```bash
terraform init
```

フォーマットを確認します。

```bash
terraform fmt -check -recursive
```

構文と依存関係を検証します。

```bash
terraform validate
```

プランを確認します。

```bash
terraform plan -var-file=terraform.tfvars
```

問題なければ、ユーザー自身で `apply` を実行してください。

```bash
terraform apply -var-file=terraform.tfvars
```

### 期待される作成物

apply 完了後、概ね次のようなリソースが作られます。

- Lambda 関数: `security-hub-ai-triage-triage-handler-dev`
- DynamoDB テーブル: `security-hub-ai-triage-dedup-dev`
- EventBridge ルール: `security-hub-ai-triage-findings-rule-dev`
- IAM ロール: `security-hub-ai-triage-lambda-role-dev`
- S3 バケット: `security-hub-ai-triage-reports-<AWSアカウントID>`

---

## ステップ 9: 作成されたリソースを確認する

### Lambda

```bash
aws lambda get-function \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --region ap-northeast-1
```

### DynamoDB

```bash
aws dynamodb describe-table \
  --table-name security-hub-ai-triage-dedup-dev \
  --region ap-northeast-1
```

### EventBridge

```bash
aws events describe-rule \
  --name security-hub-ai-triage-findings-rule-dev \
  --region ap-northeast-1
```

### S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 ls "s3://security-hub-ai-triage-reports-${ACCOUNT_ID}/"
```

---

## ステップ 10: Lambda を直接呼び出して単体動作確認する

まずテストイベントを作成します。

```bash
cat > /tmp/test_event.json <<'EOF'
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
        "CreatedAt": "2026-05-07T00:00:00Z",
        "UpdatedAt": "2026-05-07T00:00:00Z",
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
```

Lambda を実行します。

```bash
aws lambda invoke \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --payload file:///tmp/test_event.json \
  --cli-binary-format raw-in-base64-out \
  --region ap-northeast-1 \
  /tmp/response.json
```

レスポンスを確認します。

```bash
cat /tmp/response.json
```

期待例:

```json
{"processed":1,"skipped":0,"notified":1}
```

この時点で次のことが起きている想定です。

- Bedrock にトリアージ要求が送られる
- Chatwork に 1 件通知される
- S3 に 1 件レポートが保存される
- DynamoDB に処理済みレコードが作られる

---

## ステップ 11: Security Hub へテスト Finding を投入して E2E 確認する

EventBridge 経由の本来の流れを確認したい場合は、Security Hub にテスト Finding を入れます。

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
    \"CreatedAt\": \"2026-05-07T00:00:00Z\",
    \"UpdatedAt\": \"2026-05-07T00:00:00Z\",
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

期待される流れ:

1. Security Hub に Finding が入る
2. EventBridge ルールが一致する
3. Lambda が起動する
4. Chatwork に通知が来る
5. S3 と DynamoDB に記録が残る

---

## ステップ 12: CloudWatch Logs を確認する

ロググループ名:

```bash
LOG_GROUP="/aws/lambda/security-hub-ai-triage-triage-handler-dev"
```

最新ログストリーム名を取得します。

```bash
aws logs describe-log-streams \
  --log-group-name "${LOG_GROUP}" \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --region ap-northeast-1 \
  --query "logStreams[0].logStreamName" \
  --output text
```

出てきたログストリーム名を使って内容を表示します。

```bash
aws logs get-log-events \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name "LOG_STREAM_NAME" \
  --region ap-northeast-1 \
  --query "events[*].message" \
  --output text
```

確認したいログ例:

- `トリアージ開始`
- `Chatwork 通知送信成功`
- `レポートを S3 に保存しました`
- `処理済みとして記録`
- `処理完了`

---

## ステップ 13: S3 にレポートが保存されたか確認する

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="security-hub-ai-triage-reports-${ACCOUNT_ID}"
TODAY=$(date +%Y/%m/%d)

aws s3 ls "s3://${BUCKET}/findings/${TODAY}/"
```

内容を確認したい場合:

```bash
aws s3 cp "s3://${BUCKET}/findings/${TODAY}/KEY" -
```

保存される JSON には主に次が入ります。

- `original_finding`
- `triage_result`
- `processed_at`
- `model_id`

---

## ステップ 14: DynamoDB の重複排除レコードを確認する

```bash
aws dynamodb scan \
  --table-name security-hub-ai-triage-dedup-dev \
  --region ap-northeast-1 \
  --query "Items[*].{finding_id:finding_id.S,verdict:verdict.S,processed_at:processed_at.S,ttl:ttl.N}"
```

ここで確認したいこと:

- `finding_id` が記録されている
- `verdict` が保存されている
- `ttl` が 7 日後のエポック秒になっている

---

## ステップ 15: 重複排除を試す

同じ `/tmp/test_event.json` をもう一度 Lambda に送ります。

```bash
aws lambda invoke \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --payload file:///tmp/test_event.json \
  --cli-binary-format raw-in-base64-out \
  --region ap-northeast-1 \
  /tmp/response-second.json
```

2 回目は `skipped` が増えるのが期待動作です。

```bash
cat /tmp/response-second.json
```

期待例:

```json
{"processed":0,"skipped":1,"notified":0}
```

---

## GitHub Actions による自動デプロイ

このリポジトリには GitHub Actions も含まれています。

| トリガー | 実行内容 |
|---|---|
| Pull Request to `main` | `fmt` / `init` / `validate` / `plan` / PR コメント投稿 |
| Push to `main` | 上記に加えて `terraform apply` |

使う GitHub Secrets:

- `AWS_ROLE_ARN`
- `CHATWORK_SECRET_ARN`
- `CHATWORK_ROOM_ID`

OIDC ロールの信頼ポリシー例:

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

---

## よくあるハマりどころ

### Bedrock のアクセスが拒否される

- Bedrock のモデルアクセスが未許可
- Lambda 実行ロールに対象モデル ARN への `bedrock:InvokeModel` がない
- デプロイリージョンとモデル利用リージョンがずれている

確認コマンド:

```bash
aws bedrock list-foundation-models \
  --region ap-northeast-1 \
  --query "modelSummaries[?contains(modelId,'haiku')].[modelId,modelLifecycle.status]"
```

### Chatwork 通知が届かない

- Secrets Manager のシークレット値が誤っている
- ルーム ID が違う
- Lambda ログに Chatwork API エラーが出ている

確認コマンド:

```bash
aws secretsmanager get-secret-value \
  --secret-id chatwork-token \
  --region ap-northeast-1 \
  --query "SecretString"
```

### EventBridge から Lambda が起動しない

- Security Hub が有効化されていない
- EventBridge ルール名を見誤っている
- Lambda 側の invoke permission が不足している

確認コマンド:

```bash
aws events describe-rule \
  --name security-hub-ai-triage-findings-rule-dev \
  --region ap-northeast-1

aws lambda get-policy \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --region ap-northeast-1
```

### Lambda タイムアウトが起きる

- Bedrock 応答遅延
- 外部通知先の応答遅延

確認コマンド:

```bash
aws lambda get-function-configuration \
  --function-name security-hub-ai-triage-triage-handler-dev \
  --region ap-northeast-1 \
  --query "Timeout"
```

---

## コストの目安

| サービス | 概算 |
|---|---|
| Lambda | 少量実行なら無料枠内に収まりやすい |
| Bedrock | 利用トークン数に応じて課金 |
| DynamoDB | 少量ならごく小額 |
| S3 | 保存量に応じて課金 |
| EventBridge | イベント数に応じて課金 |
| Security Hub | Findings 数や有効化状態に応じて課金 |

小規模検証でも Security Hub は放置コストが出やすいため、検証後のクリーンアップは重要です。

---

## クリーンアップ

ハンズオン終了後は不要コストを避けるため、必要に応じて削除してください。

### 1. Terraform リソースを削除する

ユーザー自身で実行してください。

```bash
cd /home/takuya/terraform-lab/security-hub-ai-triage/terraform
terraform destroy -var-file=terraform.tfvars
```

### 2. Security Hub を無効化する

```bash
aws securityhub disable-security-hub --region ap-northeast-1
```

### 3. Secrets Manager のシークレットを削除する

```bash
aws secretsmanager delete-secret \
  --secret-id chatwork-token \
  --force-delete-without-recovery \
  --region ap-northeast-1
```

---

## 参考ファイル

- [ARCHITECTURE.md](/home/takuya/terraform-lab/security-hub-ai-triage/ARCHITECTURE.md)
- [terraform/main.tf](/home/takuya/terraform-lab/security-hub-ai-triage/terraform/main.tf)
- [lambda/triage_handler/handler.py](/home/takuya/terraform-lab/security-hub-ai-triage/lambda/triage_handler/handler.py)
- [.github/workflows/deploy.yml](/home/takuya/terraform-lab/security-hub-ai-triage/.github/workflows/deploy.yml)
