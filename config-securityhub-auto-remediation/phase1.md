# Phase 1 — Terraform基盤構築 (IAM / S3監査ログ / DynamoDB / VPC Endpoints / State Backend)

## このフェーズの目的

プロジェクト全体で使う基盤リソースをTerraformで構築する。
後続フェーズ（Config Rules、Lambda、Security Hub）がすべてこのフェーズの出力に依存する。

## 前提確認

以下を実行してから作業を開始すること:

```bash
aws sts get-caller-identity
aws configure get region  # ap-northeast-1 であること
terraform version         # >= 1.7.0 であること
```

## 作業ディレクトリ

```
config-securityhub-auto-remediation/
```

## 作成するリソース一覧

### 1. Terraform State Backend (S3 + DynamoDB Lock)

**ファイル**: `terraform/environments/dev/backend.tf`

```hcl
# Terraformステート管理用S3バケット
# バケット名: csar-tfstate-${data.aws_caller_identity.current.account_id}
# 設定: versioning=true, server_side_encryption=AES256, public_access_block=全true
# ロック用DynamoDB: csar-tfstate-lock (PAY_PER_REQUEST, hash_key=LockID)
```

**注意**: バックエンドバケットは `aws s3api create-bucket` で先に手動作成してから `terraform init` すること。スクリプトは `scripts/init-backend.sh` に生成する。

### 2. VPC + VPC Endpoints

**ファイル**: `terraform/modules/networking/main.tf`

以下のVPC Endpointsを作成する（NAT Gateway禁止）:

| Endpoint | 種別 | 用途 |
|----------|------|------|
| com.amazonaws.ap-northeast-1.s3 | Gateway | S3監査ログ書き込み |
| com.amazonaws.ap-northeast-1.dynamodb | Gateway | DynamoDB修復ログ書き込み |
| com.amazonaws.ap-northeast-1.ssm | Interface | SSM Parameter Store参照 |
| com.amazonaws.ap-northeast-1.lambda | Interface | Lambda間呼び出し（将来拡張用） |
| com.amazonaws.ap-northeast-1.logs | Interface | CloudWatch Logs |
| com.amazonaws.ap-northeast-1.config | Interface | Config APIコール |
| com.amazonaws.ap-northeast-1.securityhub | Interface | Security Hub APIコール |

VPC設定:
- CIDR: 10.0.0.0/16
- Private Subnet × 2 AZ (10.0.1.0/24, 10.0.2.0/24) — Lambda用
- S3/DynamoDB Gateway Endpoint は route_table に関連付け
- Interface Endpoint 用 Security Group: Lambda SG からの443のみ許可

### 3. S3 監査ログバケット

**ファイル**: `terraform/modules/audit/s3.tf`

```
バケット名: csar-audit-logs-${aws_account_id}
設定:
  - versioning: Enabled
  - server_side_encryption: AES256 (SSE-S3)
  - public_access_block: 全項目 true
  - lifecycle_rule:
      - id: glacier-transition
        prefix: "remediation-logs/"
        transition: 90日後 GLACIER
        expiration: 365日後
  - object_ownership: BucketOwnerEnforced (ACL無効)
  - logging: 別途アクセスログバケットへ（csar-access-logs-${account_id}）
```

S3 Key プレフィックス設計:
```
remediation-logs/
  year=YYYY/
    month=MM/
      day=DD/
        {remediation_id}.json
```

### 4. DynamoDB テーブル (修復ログ)

**ファイル**: `terraform/modules/audit/dynamodb.tf`

```hcl
# テーブル名: csar-remediation-log
# billing_mode: PAY_PER_REQUEST
# hash_key: remediation_id (S)
# range_key: timestamp (S)
#
# GSI: resource-type-index
#   hash_key: resource_type (S)
#   range_key: timestamp (S)
#   projection_type: ALL
#
# GSI: status-index
#   hash_key: status (S)
#   range_key: timestamp (S)
#   projection_type: ALL
#
# TTL: ttl属性を使用 (90日後のエポック秒をLambdaが計算してセット)
# encryption: aws_managed_key (SSE有効)
# point_in_time_recovery: true
```

### 5. SQS DLQ (Dead Letter Queue)

**ファイル**: `terraform/modules/audit/sqs.tf`

```
キュー名: csar-remediation-dlq
設定:
  - message_retention_seconds: 1209600 (14日)
  - kms_master_key_id: alias/aws/sqs (SSE有効)
  - visibility_timeout_seconds: 360 (Lambda timeout 300s + バッファ)

DLQアラーム (CloudWatch):
  - メトリクス: ApproximateNumberOfMessagesVisible
  - 閾値: 1以上で ALARM
  - アクション: SNS Topic → (将来的にChatwork連携)
```

### 6. SSM Parameter Store (シークレット格納先)

**ファイル**: `terraform/modules/audit/ssm.tf`

以下のパラメータを **SecureString** で作成（値はプレースホルダー）:

```
/csar/chatwork/token    → "REPLACE_ME_CHATWORK_TOKEN"
/csar/chatwork/room_id  → "REPLACE_ME_ROOM_ID"
```

**コメント**: 実際のトークンはTerraform apply後に手動で `aws ssm put-parameter --overwrite` で設定すること。

### 7. IAM ロール群

**ファイル**: `terraform/modules/iam/main.tf`

#### 7-1. Lambda 修復実行ロール (共通ベース)

```
ロール名: csar-lambda-remediation-role (≤64文字)
信頼ポリシー: lambda.amazonaws.com
管理ポリシー:
  - AWSLambdaVPCAccessExecutionRole (VPC Lambda用)
  - AWSXRayDaemonWriteAccess
インラインポリシー: csar-lambda-remediation-policy
```

インラインポリシーで許可するアクション（ワイルドカード禁止）:
```json
{
  "Statement": [
    {
      "Sid": "S3Remediation",
      "Effect": "Allow",
      "Action": [
        "s3:PutBucketPublicAccessBlock",
        "s3:PutEncryptionConfiguration",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetEncryptionConfiguration"
      ],
      "Resource": "arn:aws:s3:::*"
    },
    {
      "Sid": "IAMRemediation",
      "Effect": "Allow",
      "Action": [
        "iam:UpdateLoginProfile",
        "iam:DeleteLoginProfile",
        "iam:ListMFADevices",
        "iam:GetUser",
        "iam:ListAttachedUserPolicies"
      ],
      "Resource": "arn:aws:iam::*:user/*"
    },
    {
      "Sid": "EC2SGRemediation",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSecurityGroups",
        "ec2:RevokeSecurityGroupIngress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RDSRemediation",
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBInstances",
        "rds:ModifyDBInstance",
        "rds:CreateDBSnapshot"
      ],
      "Resource": "arn:aws:rds:ap-northeast-1:*:db:*"
    },
    {
      "Sid": "AuditLog",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:ap-northeast-1:*:table/csar-remediation-log"
    },
    {
      "Sid": "S3AuditWrite",
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::csar-audit-logs-*/remediation-logs/*"
    },
    {
      "Sid": "SSMRead",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter"],
      "Resource": "arn:aws:ssm:ap-northeast-1:*:parameter/csar/*"
    },
    {
      "Sid": "SQSDLQWrite",
      "Effect": "Allow",
      "Action": ["sqs:SendMessage"],
      "Resource": "arn:aws:sqs:ap-northeast-1:*:csar-remediation-dlq"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricData"],
      "Resource": "*"
    }
  ]
}
```

#### 7-2. Config サービスロール

```
ロール名: csar-config-service-role
信頼ポリシー: config.amazonaws.com
管理ポリシー: AWS_ConfigRole (AWS管理ポリシー)
追加インライン: S3バケット書き込み (csar-audit-logs-*への設定スナップショット)
```

#### 7-3. EventBridge ターゲット実行ロール

```
ロール名: csar-eventbridge-invoke-role
信頼ポリシー: events.amazonaws.com
インライン: lambda:InvokeFunction (修復Lambda ARN 4種のみ)
```

### 8. ファイル構成

以下のファイルをすべて生成すること:

```
terraform/
├── environments/
│   └── dev/
│       ├── main.tf          # module呼び出し
│       ├── variables.tf     # var.environment, var.aws_account_id 等
│       ├── outputs.tf       # subnet_ids, sg_id, dlq_arn, table_name 等
│       ├── backend.tf       # S3バックエンド設定
│       └── terraform.tfvars # environment="dev"
└── modules/
    ├── networking/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── audit/
    │   ├── s3.tf
    │   ├── dynamodb.tf
    │   ├── sqs.tf
    │   ├── ssm.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── iam/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf

scripts/
└── init-backend.sh          # バックエンドS3作成スクリプト

lambda/
└── shared/
    ├── audit_logger.py      # DynamoDB + S3監査ログ共通モジュール (スタブ)
    └── chatwork_notifier.py # Chatwork通知共通モジュール (スタブ)

docs/
├── architecture.md          # Mermaid図 (スタブ、Phase6で完成)
└── adr/
    ├── ADR-001-config-vs-guardduty.md     # テンプレートのみ、決定理由は空欄
    └── ADR-002-lambda-vs-ssm-automation.md # テンプレートのみ、決定理由は空欄
```

## Lambda shared モジュール (スタブ実装)

`lambda/shared/audit_logger.py`:
```python
"""
監査ログ記録モジュール
DynamoDBへの修復ログ記録とS3への監査ログ保存を担う共通モジュール。
Phase4でフル実装する。
"""
import json
import time
import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional
import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="csar-audit-logger")

JST = timezone(timedelta(hours=9))

def generate_remediation_id() -> str:
    """修復IDを生成する: csar-rem-YYYYMMDD-uuid8形式"""
    today = datetime.now(JST).strftime("%Y%m%d")
    short_uuid = str(uuid.uuid4())[:8]
    return f"csar-rem-{today}-{short_uuid}"

def record_remediation(
    remediation_id: str,
    resource_type: str,
    resource_id: str,
    rule_name: str,
    violation_detail: dict,
    remediation_action: str,
    status: str,  # SUCCESS / FAILED / MANUAL_REQUIRED
    trigger_source: str,  # CONFIG_RULE / SECURITY_HUB_CUSTOM_ACTION
    aws_account_id: str,
    region: str = "ap-northeast-1",
    table_name: str = "csar-remediation-log",
    audit_bucket: Optional[str] = None,
) -> None:
    """修復ログをDynamoDB + S3に記録する (Phase4でフル実装)"""
    # TODO: Phase4で実装
    pass
```

`lambda/shared/chatwork_notifier.py`:
```python
"""
Chatwork通知モジュール
修復結果をChatworkに通知する共通モジュール。
Phase4でフル実装する。
"""
import urllib.request
import urllib.parse
from typing import Optional
import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="csar-chatwork-notifier")

def get_chatwork_credentials() -> tuple[str, str]:
    """SSM Parameter StoreからChatwork認証情報を取得する"""
    ssm = boto3.client("ssm", region_name="ap-northeast-1")
    # TODO: Phase4でフル実装
    token = ssm.get_parameter(Name="/csar/chatwork/token", WithDecryption=True)["Parameter"]["Value"]
    room_id = ssm.get_parameter(Name="/csar/chatwork/room_id", WithDecryption=True)["Parameter"]["Value"]
    return token, room_id

def notify_remediation_result(
    resource_type: str,
    resource_id: str,
    rule_name: str,
    remediation_action: str,
    status: str,
    remediation_id: str,
) -> None:
    """修復結果をChatworkに通知する (Phase4でフル実装)"""
    # TODO: Phase4で実装
    pass
```

## ADR テンプレート

`docs/adr/ADR-001-config-vs-guardduty.md`:
```markdown
# ADR-001: AWS Config Rules vs GuardDuty — 検知手段の選定

## ステータス
決定済み

## コンテキスト
セキュリティコンプライアンス違反を自動検知・修復するにあたり、
AWS Config Rules と Amazon GuardDuty のどちらを主軸とするかを検討した。

## 検討した選択肢
- AWS Config Rules (マネージドルール + カスタムルール)
- Amazon GuardDuty
- AWS Security Hub (両者の統合層として)

## 決定
AWS Config Rules を主軸とし、Security Hub をFinding集約層として採用する。

## 決定理由
<!-- ⚠️ この欄はTakuya自身が記述してください。AI生成テキストの転用禁止 -->
<!-- 以下の観点を自分の言葉で説明してください:
  - なぜGuardDutyではなくConfig Rulesが今回の要件に合うのか
  - Config Rulesの評価タイミング（変更時/定期）がどう修復ループに影響するか
  - Security HubをFinding集約に使う理由
-->

## 結果として生じるトレードオフ
- Config Rulesは設定変更の検知が主目的。ランタイムの脅威検知はGuardDutyが得意。
- 今回はコンプライアンス違反の自動修復にフォーカスしており、Config Rulesが適切。
```

`docs/adr/ADR-002-lambda-vs-ssm-automation.md`:
```markdown
# ADR-002: Lambda vs SSM Automation — 修復実行基盤の選定

## ステータス
決定済み

## コンテキスト
Config Rules違反を検知した後の自動修復実行基盤として、
AWS Lambda と AWS Systems Manager Automation Runbook のどちらを使うかを検討した。

## 検討した選択肢
- AWS Lambda (Python 3.12)
- AWS Systems Manager Automation Runbook
- AWS Config Remediation (SSM Automationの薄いラッパー)

## 決定
AWS Lambda (Python 3.12, arm64) を修復実行基盤として採用する。

## 決定理由
<!-- ⚠️ この欄はTakuya自身が記述してください。AI生成テキストの転用禁止 -->
<!-- 以下の観点を自分の言葉で説明してください:
  - Lambdaを選んだ具体的な理由(自由度、テスタビリティ、コスト等)
  - SSM Automationで対応できないケースがあるか
  - DLQとの組み合わせにおけるエラーハンドリングの柔軟性
-->

## 結果として生じるトレードオフ
- Lambdaはコードのメンテナンスが必要。SSM Automationはマネージドで管理コスト低。
- 複雑な修復ロジック（RDSスナップショット+通知の組み合わせ等）はLambdaが有利。
```

## 実行手順

```bash
# 1. バックエンドS3バケット作成
bash scripts/init-backend.sh

# 2. Terraform初期化
cd terraform/environments/dev
terraform init

# 3. プラン確認
terraform plan -out=tfplan

# 4. 適用
terraform apply tfplan

# 5. SSMパラメータに実際の値を設定
aws ssm put-parameter \
  --name "/csar/chatwork/token" \
  --value "YOUR_CHATWORK_TOKEN" \
  --type SecureString \
  --overwrite

aws ssm put-parameter \
  --name "/csar/chatwork/room_id" \
  --value "YOUR_ROOM_ID" \
  --type SecureString \
  --overwrite
```

## 完了確認

```bash
# VPC Endpoints確認
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query "VpcEndpoints[].ServiceName"

# DynamoDBテーブル確認
aws dynamodb describe-table --table-name csar-remediation-log \
  --query "Table.{Status:TableStatus,BillingMode:BillingModeSummary.BillingMode}"

# S3バケット確認
aws s3api get-public-access-block \
  --bucket "csar-audit-logs-$(aws sts get-caller-identity --query Account --output text)"

# SQS DLQ確認
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url --queue-name csar-remediation-dlq --query QueueUrl --output text) \
  --attribute-names All
```

## 口頭説明チェック (Phase 1)

以下を見ずに説明できるか確認すること:

1. **VPC Endpointが必要な理由** — NAT GatewayなしでプライベートサブネットのLambda からAWS APIを呼ぶにはなぜEndpointが必要か？Gateway型とInterface型の違いは？

2. **DynamoDB PAY_PER_REQUESTを選んだ理由** — セキュリティ修復ワークロードの特性（バースト的、予測困難）とProvisionedモードのどちらが適しているか？

3. **SQS DLQのvisibility_timeoutをLambdaタイムアウトより長くする理由** — 360秒に設定した根拠を説明できるか？

4. **SSMパラメータをSecureStringにする理由** — StringとSecureStringの違いと、Lambda側での取得方法（WithDecryption=True）はなぜ必要か？

5. **IAMロールにワイルドカードを使わない設計の意図** — 最小権限の観点から、EC2の`RevokeSecurityGroupIngress`だけを許可することの意味は？