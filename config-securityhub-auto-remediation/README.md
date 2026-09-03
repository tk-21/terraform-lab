# config-securityhub-auto-remediation

AWS Config Rules + Security Hub Custom Action による**セキュリティコンプライアンス自動修復基盤**。

コンプライアンス違反を検知してから自動修復・監査ログ記録・CloudWatch 監視までをフルサイクルで実装。

---

## このハンズオンで得られること

このハンズオンを完走すると、以下のスキルと知識が身につきます。

### AWS サービスの実践的な組み合わせ方

| 学習項目 | 内容 |
|---------|-----|
| **AWS Config Rules** | マネージドルールを使って S3 / IAM / EC2-SG / RDS の設定違反をリアルタイムに検知する方法 |
| **Amazon EventBridge** | Config の NON_COMPLIANT イベントを受け取り、リソース種別ごとに Lambda へルーティングする方法 |
| **Security Hub Custom Action** | Findings 画面のボタンクリックで Lambda を起動する「手動トリガー修復」を実装する方法 |
| **AWS Lambda (Python)** | Lambda Powertools (Logger / Tracer / Metrics / EMF) を使った本番水準の関数実装 |
| **DLQ 二段構え設計** | EventBridge レベルの 3 回リトライ + Lambda DLQ でイベント取りこぼしをゼロにする方法 |
| **VPC Endpoints** | NAT Gateway を排除し、Interface / Gateway 型 VPC Endpoints だけで AWS API 通信を完結させる方法 |

### セキュリティ設計の実践

- IAM 最小権限設計（ワイルドカードを排除しつつ AWS の制約と折り合いをつける）
- S3 バケットポリシーによる HTTPS 強制
- DynamoDB + S3 への監査ログ二重書き設計の判断根拠

### IaC・設計思想

- 6 モジュール分割による Terraform の依存関係管理
- AWS の技術的制約（RDS 暗号化のインプレース変更不可など）を設計に正直に反映する方法
- ADR (Architecture Decision Record) で「なぜその設計を選んだか」を記録する習慣

### 完走後に「口頭で説明できる」こと

- Config Rule の評価タイミングの違い（変更ドリブン vs 定期評価 24 時間）
- Security Hub Custom Action と Config Rule の 2 トリガーパスを同一 Lambda で処理する仕組み
- RDS 暗号化を自動修復しない技術的理由とその代替策
- DLQ が必要な理由とべき等性の設計

---

## アーキテクチャ概要

詳細は [ARCHITECTURE.md](ARCHITECTURE.md) を参照。

```
【自動修復フロー】          【手動修復フロー】
Config Rule 違反検知         Security Hub Finding
       ↓                          ↓ Custom Action ボタン
 EventBridge Rule  ←─────────────→ EventBridge Rule
       ↓                    (同じ Lambda へルーティング)
  Lambda 修復関数
       ↓
  修復実行 (AWS API)
       ↓
  DynamoDB 修復ログ + S3 監査証跡
       ↓
  CloudWatch メトリクス・アラーム
```

## 修復対象リソース

| リソース | Config Rule | 違反条件 | 修復方法 |
|---------|------------|---------|---------|
| S3 | s3-bucket-public-read-prohibited | Public Access Block 無効 | Block Public Access を全有効化 |
| S3 | s3-bucket-server-side-encryption-enabled | SSE 未設定 | AES256 SSE を強制設定 |
| IAM | iam-user-mfa-enabled | MFA デバイス未設定 | コンソールアクセス (LoginProfile) を削除 |
| IAM | iam-user-no-policies-check | 直接ポリシーアタッチ | 監査ログに記録し手動対応 (自動修復不可) |
| EC2/SG | restricted-ssh | 0.0.0.0/0:22 開放 | 該当インバウンドルール削除 |
| EC2/SG | restricted-rdp | 0.0.0.0/0:3389 開放 | 該当インバウンドルール削除 |
| RDS | rds-instance-public-access-check | PubliclyAccessible=true | PubliclyAccessible=false に変更 |
| RDS | rds-storage-encrypted | 暗号化なし | スナップショット取得 + 手動対応通知 |

---

## 事前準備

### 必要なツール

```bash
# バージョン確認
terraform version   # >= 1.7.0
aws --version       # AWS CLI v2
python3 --version   # >= 3.12 (ローカルテスト用)
```

インストール方法:
- Terraform: https://developer.hashicorp.com/terraform/install
- AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

### AWS 認証情報の設定

```bash
# プロファイル確認
aws sts get-caller-identity
# 出力例:
# {
#     "UserId": "AIDAXXXXXXXXXXXXXXXXX",
#     "Account": "123456789012",
#     "Arn": "arn:aws:iam::123456789012:user/your-name"
# }
```

### 必要な IAM 権限

実行ユーザーに以下のサービスへのフル権限が必要です（管理者権限または同等の権限）:

`S3` / `DynamoDB` / `Lambda` / `IAM` / `EC2` / `RDS` / `Config` / `SecurityHub` / `EventBridge` / `SQS` / `CloudWatch` / `VPC`

---

## ハンズオン手順

### Step 1. リポジトリのクローン

```bash
git clone <repository-url>
cd config-securityhub-auto-remediation
```

### Step 2. Terraform バックエンドの初期化

Terraform の tfstate を保存する S3 バケットと、ロック用 DynamoDB テーブルを作成します。
**この手順は初回のみ実行します。**

```bash
bash scripts/init-backend.sh
```

**実行結果の確認:**

```
=== Terraformバックエンド初期化 ===
AWSアカウントID: 123456789012
バケット名: csar-tfstate-123456789012
DynamoDBテーブル: csar-tfstate-lock

[CREATE] S3バケット csar-tfstate-123456789012 を作成中...
[OK] S3バケット作成完了
[CREATE] DynamoDBテーブル csar-tfstate-lock を作成中...
[OK] DynamoDBテーブル作成完了

=== バックエンド初期化完了 ===
次のステップ:
  cd terraform/environments/dev
  terraform init -backend-config="bucket=csar-tfstate-123456789012"
```

### Step 3. Terraform init

```bash
cd terraform/environments/dev

# アカウント ID を環境変数に取得
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

terraform init -backend-config="bucket=csar-tfstate-${AWS_ACCOUNT_ID}"
```

**実行結果の確認:**

```
Initializing the backend...
Successfully configured the backend "s3"!

Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.50"...
- Installing hashicorp/aws v5.x.x...
- Installation complete.

Terraform has been successfully initialized!
```

### Step 4. Terraform plan — 作成されるリソースの確認

```bash
terraform plan
```

以下のリソースが作成されます（約 60〜70 リソース）:

```
# 主要リソース一覧
module.networking   → VPC, Subnet ×2, Route Table, SG ×2, VPC Endpoint ×7
module.audit        → S3 ×2 (監査ログ/アクセスログ), DynamoDB, SQS DLQ
module.iam          → IAM Role ×3, IAM Policy ×5
module.remediation  → Lambda ×4, Lambda Layer ×2, Lambda Permission ×8
module.config       → Config Recorder, Config Rules ×8, EventBridge Rule ×4
module.security_hub → Security Hub, Custom Action ×4, EventBridge Rule ×4
module.dashboard    → CloudWatch Dashboard, CloudWatch Alarm ×2, SNS Topic
```

### Step 5. Terraform apply — リソースの作成

```bash
terraform apply
```

`yes` を入力して実行します。完了まで **約 5〜10 分** かかります。

```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

Apply complete! Resources: 68 added, 0 changed, 0 destroyed.

Outputs:
  vpc_id                = "vpc-xxxxxxxxxxxxxxxxx"
  s3_lambda_arn         = "arn:aws:lambda:ap-northeast-1:123456789012:function:csar-remediation-s3"
  dynamodb_table_name   = "csar-remediation-log"
  audit_bucket_name     = "csar-audit-logs-123456789012"
  dashboard_url         = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home#dashboards:name=CSAR-AutoRemediation"
```

### Step 6. デプロイ確認

すべてのリソースが正常に作成されたか確認します。

```bash
# Lambda 関数の確認
aws lambda list-functions \
  --query "Functions[?contains(FunctionName,'csar')].{Name:FunctionName,Runtime:Runtime,Arch:Architectures[0]}" \
  --output table

# 期待される出力:
# -----------------------------------------------------------
# |                     ListFunctions                       |
# +---+-----------------------------+----------+-------+----+
# |Arch      | Name                         | Runtime     |
# +----------+------------------------------+-------------+
# | arm64    | csar-remediation-s3          | python3.12  |
# | arm64    | csar-remediation-iam         | python3.12  |
# | arm64    | csar-remediation-ec2-sg      | python3.12  |
# | arm64    | csar-remediation-rds         | python3.12  |
# +----------+------------------------------+-------------+

# Config Rules の確認
aws configservice describe-config-rules \
  --query "ConfigRules[?contains(ConfigRuleName,'csar')].{Name:ConfigRuleName,State:ConfigRuleState}" \
  --output table

# Security Hub Custom Action の確認
aws securityhub describe-action-targets \
  --query "ActionTargets[].{Name:Name,Id:ActionTargetArn}" \
  --output table

# CloudWatch Dashboard の確認
aws cloudwatch get-dashboard --dashboard-name CSAR-AutoRemediation > /dev/null && echo "Dashboard: OK"
```

---

## 統合テスト

実際に違反を発生させ、自動修復が動くことを確認します。

### テスト前の確認: AWS Config の初期リソース検出

AWS Config を初めて有効化した直後は、既存リソースの初期検出が完了するまで評価結果が空になることがあります。初期検出は AWS 側の非同期処理であり、ケースによっては最大 24 時間かかることがあります。

> `start-config-rules-evaluation` は最後に記録された構成を再評価するだけで、新しいリソース検出は実行しません。

以下を実行し、Recorder が起動済みで、少なくとも 1 件のリソースが検出されていることを確認してからテストしてください。

```bash
# Recorder が稼働中であることを確認する
aws configservice describe-configuration-recorder-status \
  --configuration-recorder-names csar-config-recorder \
  --region ap-northeast-1

# totalDiscoveredResources が 1 以上になるまで待つ
aws configservice get-discovered-resource-counts \
  --region ap-northeast-1
```

期待値は `recording: true`、`lastStatus: SUCCESS`、および `totalDiscoveredResources: 1` 以上です。初期検出中は数分おきに再確認してください。

### テスト 1: S3 Public Access 自動修復

**所要時間: 約 5〜10 分**

**Step 1 — 違反バケットを作成する**

```bash
cd ../../..  # プロジェクトルートに戻る
bash tests/integration/create_violation_s3.sh
```

出力に表示されたバケット名を控えてください:
```
=== S3違反バケット作成: csar-test-violation-1736985600 ===
違反バケット作成完了: csar-test-violation-1736985600
```

**Step 2 — Config Rule の評価を手動トリガーする**

初期リソース検出の完了後は、Config Rule は通常、変更検知から数分以内に自動評価されます。必要に応じて、手動で再評価できます:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names csar-s3-bucket-public-read-prohibited \
  --region ap-northeast-1
```

**Step 3 — 評価結果を確認する (2〜3 分後)**

```bash
BUCKET_NAME="csar-test-violation-xxxxxxxxxx"  # Step 1 で控えたバケット名

aws configservice get-compliance-details-by-config-rule \
  --config-rule-name csar-s3-bucket-public-read-prohibited \
  --compliance-types NON_COMPLIANT \
  --query "EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId=='${BUCKET_NAME}'].ComplianceType"
```

期待される出力: `["NON_COMPLIANT"]`

**Step 4 — Lambda の実行ログを確認する**

```bash
aws logs filter-log-events \
  --log-group-name "/aws/lambda/csar-remediation-s3" \
  --filter-pattern "修復対象" \
  --start-time $(date -d '10 minutes ago' +%s 2>/dev/null || date -v-10M +%s)000 \
  --query "events[].message"
```

**Step 5 — 修復結果を確認する**

```bash
# Block Public Access が有効化されているか
aws s3api get-public-access-block --bucket "${BUCKET_NAME}"
```

期待される出力:
```json
{
    "PublicAccessBlockConfiguration": {
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }
}
```

**Step 6 — DynamoDB の修復ログを確認する**

```bash
aws dynamodb scan \
  --table-name csar-remediation-log \
  --filter-expression "resource_id = :rid" \
  --expression-attribute-values "{\":rid\":{\"S\":\"${BUCKET_NAME}\"}}" \
  --query "Items[0].{id:remediation_id.S,status:status.S,action:remediation_action.S,trigger:trigger_source.S}"
```

期待される出力:
```json
{
    "id": "csar-rem-20250115-a1b2c3d4",
    "status": "SUCCESS",
    "action": "Block Public Access を有効化",
    "trigger": "CONFIG_RULE"
}
```

**Step 7 — クリーンアップ**

```bash
aws s3 rb s3://${BUCKET_NAME} --force
```

---

### テスト 2: Security Group SSH 自動修復

**所要時間: 約 3〜5 分**

**Step 1 — 違反 SG を作成する**

```bash
bash tests/integration/create_violation_sg.sh
```

デフォルトでは `dev` 環境の VPC (`csar-vpc-dev`) を使用します。別環境をテストする場合は `ENVIRONMENT` を指定してください。

```bash
ENVIRONMENT=prod bash tests/integration/create_violation_sg.sh
```

SG ID を控えてください:
```
対象VPC: vpc-xxxxxxxxxxxxxxxxx
Security Group作成完了: sg-xxxxxxxxxxxxxxxxx
SSH 0.0.0.0/0 インバウンドルール追加完了 (違反状態)
```

**Step 2 — Config Rule を評価する**

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names csar-restricted-ssh \
  --region ap-northeast-1
```

**Step 3 — 修復結果を確認する (2〜3 分後)**

```bash
SG_ID="sg-xxxxxxxxxxxxxxxxx"  # Step 1 で控えた SG ID

aws ec2 describe-security-groups \
  --group-ids "${SG_ID}" \
  --query "SecurityGroups[0].IpPermissions"
```

期待される出力: `[]`（SSH 0.0.0.0/0 のルールが削除されている）

**Step 4 — クリーンアップ**

```bash
aws ec2 delete-security-group --group-id "${SG_ID}"
```

---

### テスト 3: IAM MFA 未設定 自動修復

**所要時間: 約 5 分（手動トリガーが必要）**

> IAM MFA ルールは定期評価（24 時間ごと）のため、手動トリガーが必要です。

**Step 1 — 違反ユーザーを作成する**

```bash
bash tests/integration/create_violation_iam.sh
```

ユーザー名を控えてください:
```
=== IAM違反ユーザー作成: csar-test-violation-user-1736985600 ===
IAMユーザー作成完了: csar-test-violation-user-1736985600 (MFA未設定=違反状態)
```

**Step 2 — Config Rule を手動トリガーする**

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names csar-iam-user-mfa-enabled
```

**Step 3 — 修復結果を確認する (2〜3 分後)**

```bash
USERNAME="csar-test-violation-user-xxxxxxxxxx"

# LoginProfile が削除されているか確認
aws iam get-login-profile --user-name "${USERNAME}" 2>&1
```

期待される出力:
```
An error occurred (NoSuchEntity) when calling the GetLoginProfile operation:
Login Profile for User csar-test-violation-user-xxxxxxxxxx cannot be found.
```

ログインプロファイルが削除され、コンソールアクセスが無効化されています。

**Step 4 — クリーンアップ**

```bash
aws iam delete-login-profile --user-name "${USERNAME}" 2>/dev/null || true
aws iam delete-user --user-name "${USERNAME}"
```

---

### テスト 4: Security Hub Custom Action（手動トリガー）

Config Rule の自動修復とは別に、Security Hub の画面から手動で修復をトリガーできます。

**Step 1 — Security Hub の Findings を開く**

```
https://ap-northeast-1.console.aws.amazon.com/securityhub/home#/findings
```

**Step 2 — Config 由来の Finding にチェックを入れる**

- Product name = `Config` でフィルタリング
- 修復したいリソースの Finding を選択（チェックボックス）

**Step 3 — Custom Action を実行する**

- 画面上部の **[アクション]** をクリック
- ドロップダウンから修復アクションを選択:
  - `CSAR: S3 Remediate`
  - `CSAR: IAM Remediate`
  - `CSAR: SG Remediate`
  - `CSAR: RDS Review`

**Step 4 — ログで `SECURITY_HUB_CUSTOM_ACTION` トリガーを確認する**

```bash
aws logs filter-log-events \
  --log-group-name "/aws/lambda/csar-remediation-s3" \
  --filter-pattern "SECURITY_HUB_CUSTOM_ACTION" \
  --start-time $(date -d '5 minutes ago' +%s 2>/dev/null || date -v-5M +%s)000 \
  --query "events[].message"
```

DynamoDB の `trigger_source` が `SECURITY_HUB_CUSTOM_ACTION` になっていることを確認します。

---

### テスト 5: DLQ フロー（意図的な失敗）

Lambda が失敗したときに DLQ へメッセージが積まれることを確認します。

**Step 1 — 存在しないリソースを含むイベントを直接 invoke する**

```bash
aws lambda invoke \
  --function-name csar-remediation-s3 \
  --payload '{
    "detail-type": "Config Rules Compliance Change",
    "detail": {
      "configRuleName": "csar-s3-bucket-public-read-prohibited",
      "resourceId": "csar-nonexistent-bucket-99999",
      "resourceType": "AWS::S3::Bucket",
      "newEvaluationResult": {"complianceType": "NON_COMPLIANT"}
    }
  }' \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda_response.json && cat /tmp/lambda_response.json
```

**Step 2 — DLQ にメッセージが積まれているか確認する（30 秒後）**

```bash
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name csar-remediation-dlq \
  --query QueueUrl --output text)

aws sqs get-queue-attributes \
  --queue-url "${DLQ_URL}" \
  --attribute-names ApproximateNumberOfMessagesVisible \
  --query "Attributes.ApproximateNumberOfMessagesVisible"
```

期待される出力: `"1"` 以上

**Step 3 — DLQ のメッセージ内容を確認する**

```bash
aws sqs receive-message \
  --queue-url "${DLQ_URL}" \
  --max-number-of-messages 1 \
  --query "Messages[0].Body" \
  --output text | python3 -m json.tool
```

**Step 4 — DLQ メッセージを削除する（テスト後のクリーンアップ）**

```bash
RECEIPT_HANDLE=$(aws sqs receive-message \
  --queue-url "${DLQ_URL}" \
  --query "Messages[0].ReceiptHandle" --output text)

aws sqs delete-message \
  --queue-url "${DLQ_URL}" \
  --receipt-handle "${RECEIPT_HANDLE}"
```

---

## CloudWatch Dashboard の確認

テスト実行後、ダッシュボードで修復状況を視覚的に確認できます。

```
https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home#dashboards:name=CSAR-AutoRemediation
```

確認ポイント:
- **修復成功数**: テストで実行した修復がカウントされているか
- **DLQ メッセージ数**: テスト 5 後に 1 以上になっているか（クリーンアップ後は 0）
- **Lambda エラー率**: テスト 5 後にエラーが記録されているか
- **Lambda 実行時間 P99**: タイムアウト 300s に対して十分なマージンがあるか

---

## 環境の削除（クリーンアップ）

ハンズオン終了後は、コストが継続発生しないよう必ず削除してください。

> Interface VPC Endpoints は約 $0.014/時間 × 10 エンドポイント ≒ **$0.14/時間** 発生します。

```bash
cd terraform/environments/dev

# Terraform で作成したすべてのリソースを削除
terraform destroy
```

`yes` を入力して実行します。完了まで通常は 5〜10 分です。Lambda が VPC に接続されているため、削除済みの Lambda 関数に紐づく VPC ENI の解放待ちで、Subnet と Lambda 用 Security Group の削除に最大 20 分程度かかることがあります。

> `AWS Lambda VPC ENI` が `in-use` の場合は AWS が非同期で回収中です。手動で ENI を削除したり、`terraform destroy` を中断したりせず、そのまま完了またはエラーになるまで待機してください。

### `BucketNotEmpty` で destroy が失敗した場合

監査ログバケットとアクセスログバケットは、誤削除を防ぐため `force_destroy = false`、かつバージョニング有効で作成しています。そのため、バケット内にオブジェクトの過去バージョンまたは削除マーカーが残っていると、Terraform はバケットを削除できません。

エラーに表示されたバケット名を指定して、全バージョンを削除してから `terraform destroy` を再実行してください。以下は開発環境の少量のログを削除する手順です。

```bash
BUCKET="csar-audit-logs-$(aws sts get-caller-identity --query Account --output text)"
VERSIONS_FILE=$(mktemp)
DELETE_FILE=$(mktemp)

aws s3api list-object-versions \
  --bucket "${BUCKET}" \
  --output json > "${VERSIONS_FILE}"

jq -c \
  '{Objects: ((.Versions // []) + (.DeleteMarkers // []) | map({Key, VersionId})), Quiet: true}' \
  "${VERSIONS_FILE}" > "${DELETE_FILE}"

cat "${DELETE_FILE}"

if jq -e '.Objects | length > 0' "${DELETE_FILE}" > /dev/null; then
  aws s3api delete-objects \
    --bucket "${BUCKET}" \
    --delete "file://${DELETE_FILE}"
else
  echo "削除対象のオブジェクトバージョンはありません"
fi

rm -f "${VERSIONS_FILE}" "${DELETE_FILE}"
terraform destroy
```

`csar-access-logs-<AWSアカウントID>` で同じエラーが出た場合は、`BUCKET` をそのバケット名に変更して同じ手順を実行します。`NoSuchBucket` はバケットがすでに削除済みであることを示すため、次のリソースの削除を続けてください。

```bash
# バックエンド用リソースも削除する場合（tfstate も削除されます）
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws s3 rb s3://csar-tfstate-${AWS_ACCOUNT_ID} --force
aws dynamodb delete-table --table-name csar-tfstate-lock
```

---

## トラブルシューティング

### `Error: creating Config Recorder: MaxNumberOfConfigurationRecordersExceededException`

AWS アカウント内に Config Recorder が既に存在しています。

```bash
# 既存の Recorder 名を確認
aws configservice describe-configuration-recorders --query "ConfigurationRecorders[].name"

# terraform.tfvars に既存の Recorder 名を設定するか、マネジメントコンソールで削除してから再実行
```

### `Error: Error enabling Security Hub: ResourceConflictException`

Security Hub が既に有効化されています。`terraform import` でインポートしてください:

```bash
terraform import module.security_hub.aws_securityhub_account.main ap-northeast-1
```

### Lambda が実行されない（Config Rule 評価後も修復されない）

```bash
# EventBridge ルールが有効か確認
aws events list-rules --name-prefix "csar-" \
  --query "Rules[].{Name:Name,State:State}"

# Lambda のトリガー権限を確認
aws lambda get-policy --function-name csar-remediation-s3 \
  --query "Policy" --output text | python3 -m json.tool
```

### SG 修復 Lambda が EC2 API の接続タイムアウトで失敗する

`Connect timeout on endpoint URL: "https://ec2.ap-northeast-1.amazonaws.com/"` が Lambda ログに出る場合、Lambda から EC2 API へ到達できていません。SG 修復は `DescribeSecurityGroups` と `RevokeSecurityGroupIngress` を呼び出すため、NAT Gateway を使用しない本構成では EC2 用 Interface VPC Endpoint が必要です。

本リポジトリには `com.amazonaws.ap-northeast-1.ec2` を追加済みです。既存環境には、次の変更を適用してください。

```bash
cd terraform/environments/dev
terraform plan
terraform apply
```

過去に失敗した非同期呼び出しは再実行されないため、適用後に Config Rule を再評価します。

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names csar-restricted-ssh \
  --region ap-northeast-1

aws logs tail /aws/lambda/csar-remediation-ec2-sg \
  --since 10m \
  --region ap-northeast-1
```

### Config Rule の評価結果が空

`get-compliance-details-by-config-rule` の `EvaluationResults` が空の場合、AWS Config が対象リソースをまだ記録していない可能性があります。まず Recorder と検出件数を確認します。

```bash
aws configservice describe-configuration-recorder-status \
  --configuration-recorder-names csar-config-recorder \
  --region ap-northeast-1

aws configservice get-discovered-resource-counts \
  --region ap-northeast-1
```

`recording: true` かつ `totalDiscoveredResources: 0` の場合は、初期リソース検出中です。`start-config-rules-evaluation` は検出を促進しないため、検出件数が増えてから再評価してください。初期検出が長時間進まない場合は、Delivery Channel の状態を確認します。

```bash
aws configservice describe-delivery-channel-status \
  --delivery-channel-names csar-config-delivery \
  --region ap-northeast-1
```

---

## 技術スタック

| カテゴリ | 技術 |
|---------|-----|
| **検知** | AWS Config Rules (マネージドルール × 8) |
| **集約** | Amazon Security Hub + Custom Action × 4 |
| **ルーティング** | Amazon EventBridge (Rule × 8) |
| **修復** | AWS Lambda (Python 3.12 / arm64 / Lambda Powertools v3) |
| **記録** | Amazon DynamoDB (修復ログ, TTL 90日) + Amazon S3 (監査証跡) |
| **監視** | CloudWatch Metrics / Alarms + SNS Topic |
| **ネットワーク** | VPC Endpoints (Gateway × 2, Interface × 5) |
| **IaC** | Terraform >= 1.7.0 |
| **コスト** | ~$16〜21/月 (NAT Gateway 排除で ~$35/月削減) |

## ドキュメント

| ドキュメント | 内容 |
|-----------|-----|
| [ARCHITECTURE.md](ARCHITECTURE.md) | システム設計の詳細（Mermaid 図・IAM 設計・データモデル） |
| [docs/architecture.md](docs/architecture.md) | アーキテクチャ Mermaid 図・EventBridge 配線マトリクス |
| [docs/adr/ADR-001](docs/adr/ADR-001-config-vs-guardduty.md) | Config Rules vs GuardDuty の選定理由 |
| [docs/adr/ADR-002](docs/adr/ADR-002-lambda-vs-ssm-automation.md) | Lambda vs SSM Automation の選定理由 |
| [docs/adr/ADR-003](docs/adr/ADR-003-securityhub-integration.md) | Security Hub Custom Action の設計理由 |
| [docs/adr/ADR-004](docs/adr/ADR-004-audit-storage.md) | DynamoDB + S3 二重書き設計の理由 |

## ディレクトリ構成

```
config-securityhub-auto-remediation/
├── ARCHITECTURE.md             # システム設計の完全ドキュメント
├── README.md                   # このファイル
├── terraform/
│   ├── environments/dev/       # 環境設定・モジュール呼び出し
│   └── modules/
│       ├── networking/         # VPC / Subnet / VPC Endpoints
│       ├── audit/              # S3監査ログ / DynamoDB / SQS DLQ
│       ├── iam/                # 最小権限 IAM ロール群
│       ├── remediation/        # Lambda × 4 / Lambda Layer
│       ├── config/             # Config Recorder / Rules × 8 / EventBridge
│       ├── security_hub/       # Security Hub / Custom Action × 4
│       └── dashboard/          # CloudWatch Dashboard / Alarms
├── lambda/
│   ├── remediation/            # 修復 Lambda × 4 (S3 / IAM / EC2-SG / RDS)
│   └── shared/                 # 共通モジュール (監査ログ)
├── tests/
│   └── integration/            # 違反シミュレーションスクリプト × 3
├── scripts/
│   └── init-backend.sh         # Terraform バックエンド初期化
└── docs/
    ├── architecture.md
    └── adr/                    # Architecture Decision Records × 4
```
