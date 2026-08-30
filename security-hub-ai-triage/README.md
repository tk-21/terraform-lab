# security-hub-ai-triage

Security Hub の Findings を EventBridge で受け取り、Amazon Bedrock で自動トリアージし、重要なものだけを Amazon SNS（メール）で通知しつつ、全件を S3 に保存するサーバレスシステムです。

詳細な構成理解は [ARCHITECTURE.md](/home/takuya/terraform-lab/security-hub-ai-triage/ARCHITECTURE.md) を参照してください。  
この README は「このプロジェクトを実際にハンズオンで動かす」ことに特化しています。

## この仕組みで何がうれしいか

これは脆弱性を自動修復する仕組みではなく、Security Hub の大量の検知結果を**人が対応しやすい形へ整理して渡す仕組み**です。

Security Hub の Finding が増えると、すべてを同じ優先度で確認する運用では通知疲れや対応漏れが起きやすくなります。この仕組みは、次の流れで人の確認作業を減らします。

```text
大量の Finding
  -> 重複を除く
  -> AI が優先度・理由・推奨対応を日本語で要約
  -> CRITICAL / HIGH だけを即時通知
  -> 全件の証跡は S3 に保存
```

| 困りごと | この仕組みによる変化 |
|---|---|
| 同じ Finding が何度も届く | DynamoDB で 7 日間の重複処理を防ぐ |
| すべてを目視で優先順位付けする | Bedrock が「なぜ重要か」「何をすべきか」を日本語で補助する |
| 通知が多すぎて重要なものを見落とす | `CRITICAL` / `HIGH` だけを SNS で即時通知する |
| 後から判断根拠を確認できない | 元 Finding と AI 判定を S3 に残す |

テスト Finding が数件だけのハンズオンでは効果を実感しにくいですが、継続的に多くの Finding が発生する環境ほど価値が出ます。

### このハンズオンでしないこと

- Finding を自動で修復・遮断すること
- AI 判定だけで人の承認なしにインフラを変更すること
- `MEDIUM` / `LOW` Finding を捨てること（通知せず S3 に保存する）

実運用では、SNS 通知を Slack / Teams / PagerDuty に連携したり、`CRITICAL` Finding から Jira や ServiceNow のチケットを作成したりすると、対応フローまで一貫して自動化できます。

## このハンズオンで得られること

- Security Hub の Finding をイベント駆動で処理する流れを理解できる
- EventBridge、Lambda、DynamoDB、S3、Bedrock を組み合わせた実践的なサーバレス構成を体験できる
- Bedrock を使ったセキュリティ運用の自動トリアージの基本パターンを学べる
- Amazon SNS を使った AWS 内で完結する通知の設定方法を確認できる
- Terraform でセキュリティ運用基盤を構築する手順を一通りなぞれる
- SNS 通知、S3 保存、DynamoDB 重複排除まで含めた E2E の確認方法を身につけられる

## できること

- Security Hub の Finding を自動受信
- Bedrock で日本語トリアージ
- `CRITICAL` / `HIGH` のみ SNS メール通知
- 全件を S3 に JSON 保存
- DynamoDB で 7 日間の重複排除

## 全体像

```text
Security Hub
  -> EventBridge Rule
  -> Lambda (triage-handler)
     -> DynamoDB で重複チェック
     -> Bedrock で AI トリアージ
     -> Amazon SNS に通知（CRITICAL/HIGH のみ）
     -> S3 にフルレポート保存
     -> DynamoDB に処理済み記録
```

## この README の進め方

このハンズオンは次の順で進めます。

1. ローカル環境を確認する
2. Bedrock と Security Hub を準備する
3. SNS 通知先メールアドレスを用意する
4. Terraform 変数を設定する
5. Terraform でリソースを作成し、SNS メール購読を確認する
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
- SNS 通知を受け取れるメールアドレス
- Bedrock の対象モデル利用権限

### AWS 側の前提

- 作業リージョンは `ap-northeast-1`
- Security Hub が有効化済み
- Bedrock で `jp.anthropic.claude-haiku-4-5-20251001-v1:0` 推論プロファイルを利用可能
- Terraform で IAM / Lambda / EventBridge / DynamoDB / S3 / SNS を作成できる

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

## ステップ 2: Bedrock 推論プロファイルと初回利用を確認する

このシステムはデフォルトで `jp.anthropic.claude-haiku-4-5-20251001-v1:0` 推論プロファイルを使います。
AWS コンソールの `Amazon Bedrock > Cross-Region inference` で対象プロファイルが利用可能か確認してください。

CLI で存在確認する例:

```bash
aws bedrock list-inference-profiles \
  --region ap-northeast-1 \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'claude-haiku-4-5')].[inferenceProfileId,status]"
```

`jp.anthropic.claude-haiku-4-5-20251001-v1:0` が `ACTIVE` なら、推論プロファイルは利用可能です。

### Anthropic モデルの初回利用を完了する

Model access ページは廃止され、初回呼び出し時にアカウント全体でモデルアクセスが有効化されます。Anthropic モデルは、初回利用時に用途情報や AWS Marketplace の利用規約承認を求められる場合があります。

管理者権限または AWS Marketplace の購読権限を持つユーザーで、Bedrock の Model catalog から Claude Haiku 4.5 を Playground で開き、`jp.anthropic.claude-haiku-4-5-20251001-v1:0` を選んで短いプロンプトを一度実行してください。

> Lambda 実行ロールには Marketplace 購読権限を追加しません。初回利用を完了した後は、Lambda の最小権限 `bedrock:InvokeModel` だけで呼び出せます。

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

## ステップ 4: SNS 通知先メールアドレスを用意する

`CRITICAL` / `HIGH` Finding の通知を受け取るメールアドレスを用意します。Terraform が SNS Topic とメール購読を作成し、AWS から購読確認メールが届きます。

> SNS の購読確認は、Terraform の apply 後にメール内の **Confirm subscription** を選ぶまで有効になりません。

---

## ステップ 5: Terraform 変数ファイルを作成する

サンプルファイルをコピーします。

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を次のように編集します。

```hcl
project_name           = "security-hub-ai-triage"
environment            = "dev"
aws_region             = "ap-northeast-1"
sns_notification_email = "your-email@example.com"
bedrock_model_id       = "jp.anthropic.claude-haiku-4-5-20251001-v1:0"
```

各値の意味:

- `project_name`: 作成されるリソース名のプレフィックス
- `environment`: `dev` / `stg` / `prod` など
- `aws_region`: デプロイ先リージョン
- `sns_notification_email`: SNS のメール通知先。apply 後に届く購読確認メールで承認する
- `bedrock_model_id`: Lambda が呼ぶ Bedrock 推論プロファイル ID

`sns_notification_email` は Terraform 上で機密値として扱われ、plan / apply の表示ではマスクされます。ただし SNS 購読先として Terraform state には保存されるため、state の保管先は暗号化し、アクセスを必要最小限にしてください。

---

## ステップ 6: Terraform 実行前に内容を確認する

このプロジェクトでは次の AWS リソースが作成されます。

- Lambda 関数
- IAM ロールとインラインポリシー
- EventBridge ルール
- DynamoDB テーブル
- S3 バケット
- SNS Topic とメール購読

主な名前例:

- Lambda: `security-hub-ai-triage-triage-handler-dev`
- DynamoDB: `security-hub-ai-triage-dedup-dev`
- EventBridge Rule: `security-hub-ai-triage-findings-rule-dev`
- IAM Role: `security-hub-ai-triage-lambda-role-dev`
- S3: `security-hub-ai-triage-reports-<ACCOUNT_ID>`

---

## ステップ 7: Terraform を実行する

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
- SNS Topic: `security-hub-ai-triage-alerts-dev`

apply 後、指定したメールアドレスに届く SNS の購読確認メールを開き、**Confirm subscription** を選択してください。

---

## ステップ 8: 作成されたリソースを確認する

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

### SNS

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "arn:aws:sns:ap-northeast-1:${ACCOUNT_ID}:security-hub-ai-triage-alerts-dev" \
  --region ap-northeast-1
```

`SubscriptionArn` が `PendingConfirmation` なら、メール内の購読確認を完了してください。

購読が有効な場合、`SubscriptionArn` は `arn:aws:sns:` で始まる値になります。`Deleted` の場合は、以降のトラブルシューティングにある手順で購読を再作成してください。

---

## ステップ 9: Lambda を直接呼び出して単体動作確認する

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
- SNS 購読メールアドレスに 1 件通知される
- S3 に 1 件レポートが保存される
- DynamoDB に処理済みレコードが作られる

同じイベントを再実行すると DynamoDB の重複排除により `skipped=1` になります。再テストする場合は、`Id` の末尾を `test-finding-002` のような未使用の値に変更してください。

---

## ステップ 10: Security Hub へテスト Finding を投入して E2E 確認する

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
4. SNS 購読メールアドレスに通知が来る
5. S3 と DynamoDB に記録が残る

同じコマンドを再実行する場合は、`Id` の `test-finding-e2e-001` を未使用の値へ変更してください。

---

## ステップ 11: CloudWatch Logs を確認する

ロググループ名:

```bash
LOG_GROUP="/aws/lambda/security-hub-ai-triage-triage-handler-dev"
```

最新ログストリーム名を取得して変数へ保存します。

```bash
LOG_STREAM=$(aws logs describe-log-streams \
  --log-group-name "${LOG_GROUP}" \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --region ap-northeast-1 \
  --query "logStreams[0].logStreamName" \
  --output text)
```

ログ内容を表示します。変数を使うため、ログストリーム名に含まれる `$LATEST` がシェル展開されません。

```bash
aws logs get-log-events \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name "${LOG_STREAM}" \
  --start-from-head \
  --region ap-northeast-1 \
  --output json
```

確認したいログ例:

- `トリアージ開始`
- `SNS 通知送信成功`
- `レポートを S3 に保存しました`
- `処理済みとして記録`
- `処理完了`

---

## ステップ 12: S3 にレポートが保存されたか確認する

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

## ステップ 13: DynamoDB の重複排除レコードを確認する

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

## ステップ 14: 重複排除を試す

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
- `SNS_NOTIFICATION_EMAIL`

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

`Model access page has been retired` は異常ではありません。Bedrock のモデルアクセスは初回呼び出し時に有効化されます。

#### `on-demand throughput isn't supported` が表示される

Claude Haiku 4.5 は基盤モデル ID を直接指定できず、推論プロファイル ID を指定する必要があります。

- 誤: `anthropic.claude-haiku-4-5-20251001-v1:0`
- 正: `jp.anthropic.claude-haiku-4-5-20251001-v1:0`

`terraform.tfvars` の `bedrock_model_id` を正しい値に更新し、Terraform を再 apply してください。推論プロファイルを使う IAM ポリシーでは、プロファイル ARN に加え、配下の東京・大阪の基盤モデル ARN への `bedrock:InvokeModel` も必要です。

#### `aws-marketplace:ViewSubscriptions` / `Subscribe` が表示される

アカウントで Anthropic モデルを初めて使うときは、AWS Marketplace の利用契約が必要です。Lambda 実行ロールへ Marketplace 権限を恒久的に追加せず、管理者権限を持つユーザーが次を行ってください。

1. Bedrock の Model catalog から Claude Haiku 4.5 を Playground で開く
2. `jp.anthropic.claude-haiku-4-5-20251001-v1:0` を選び、短いプロンプトを実行する
3. 用途情報・利用規約が表示された場合は承認する
4. 数分待ってから、新しい Finding ID で Lambda を再実行する

`AdministratorAccess` を持つユーザーでも、SCP・Permissions Boundary・セッションポリシーに明示的な `Deny` がある場合は購読できません。

確認コマンド:

```bash
aws bedrock list-inference-profiles \
  --region ap-northeast-1 \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'claude-haiku-4-5')].[inferenceProfileId,status]"
```

### Lambda が `skipped=1` になる

DynamoDB の重複排除が正常に働いています。同じ Finding ID は 7 日間スキップされるため、再テストでは `Id` を `test-finding-005` のような未使用の値に変更してください。

### SNS 通知が届かない

- SNS の購読確認メールで **Confirm subscription** を完了していない
- `sns_notification_email` が誤っている
- Lambda ログに SNS の publish エラーが出ている

確認コマンド:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "arn:aws:sns:ap-northeast-1:ACCOUNT_ID:security-hub-ai-triage-alerts-dev" \
  --region ap-northeast-1 \
  --query "Subscriptions[*].{Endpoint:Endpoint,Status:SubscriptionArn}"
```

`SubscriptionArn` が `Deleted` の購読は復活できません。購読リソースを強制再作成し、新たに届く確認メールで **Confirm subscription** を選択してください。

```bash
cd /home/takuya/terraform-lab/security-hub-ai-triage/terraform
terraform apply \
  -var-file=terraform.tfvars \
  -replace='module.sns.aws_sns_topic_subscription.email'
```

有効な状態では `SubscriptionArn` に ARN が表示されます。`PendingConfirmation` はメール確認待ちです。

### CloudWatch Logs の表示が `None` になる

`None` はログストリーム名ではなく、`--query "events[*].message"` の検索結果です。対象ストリームにイベントがない場合に表示されます。`$LATEST` がシェル展開されないよう、ログストリーム名をシングルクォートで囲みます。

```bash
aws logs get-log-events \
  --log-group-name "/aws/lambda/security-hub-ai-triage-triage-handler-dev" \
  --log-stream-name 'YYYY/MM/DD/[$LATEST]LOG_STREAM_ID' \
  --start-from-head \
  --region ap-northeast-1 \
  --output json
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

### `terraform destroy` で `BucketNotEmpty` になる

レポート保存バケットはバージョニング有効です。S3 に現行オブジェクトまたは過去バージョンが残っていると、バケットを削除できません。

このプロジェクトでは、誤削除防止のため `s3_force_destroy` は既定で `false` です。クリーンアップする場合は、先に S3 バケットだけへ削除設定を反映してから destroy を実行します。

```bash
cd /home/takuya/terraform-lab/security-hub-ai-triage/terraform

terraform apply \
  -target='module.s3.aws_s3_bucket.reports' \
  -var-file=terraform.tfvars \
  -var="s3_force_destroy=true"

terraform destroy \
  -var-file=terraform.tfvars \
  -var="s3_force_destroy=true"
```

この操作は S3 の全レポートと過去バージョンを完全に削除します。必要なデータは事前に退避してください。

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

terraform apply \
  -target='module.s3.aws_s3_bucket.reports' \
  -var-file=terraform.tfvars \
  -var="s3_force_destroy=true"

terraform destroy \
  -var-file=terraform.tfvars \
  -var="s3_force_destroy=true"
```

`s3_force_destroy=true` は、S3 バケット内のレポートと過去バージョンをすべて完全に削除します。必要なレポートは事前に退避してください。

### 2. Security Hub を無効化する

```bash
aws securityhub disable-security-hub --region ap-northeast-1
```

SNS Topic と購読は `terraform destroy` により削除されます。メール購読に対する追加の削除操作は不要です。

---

## 参考ファイル

- [ARCHITECTURE.md](/home/takuya/terraform-lab/security-hub-ai-triage/ARCHITECTURE.md)
- [terraform/main.tf](/home/takuya/terraform-lab/security-hub-ai-triage/terraform/main.tf)
- [lambda/triage_handler/handler.py](/home/takuya/terraform-lab/security-hub-ai-triage/lambda/triage_handler/handler.py)
- [.github/workflows/deploy.yml](/home/takuya/terraform-lab/security-hub-ai-triage/.github/workflows/deploy.yml)
