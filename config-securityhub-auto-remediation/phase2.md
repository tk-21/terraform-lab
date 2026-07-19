# Phase 2 — AWS Config Rules 実装 (S3 / IAM / EC2-SG / RDS)

## このフェーズの目的

6種のマネージドConfig Rulesを有効化し、Config Recorder・Delivery Channelを設定する。
EventBridgeへの連携口を完成させる（Lambdaはまだ存在しないが配線は完成させる）。

## 前提確認

```bash
# Phase1のoutputsを確認
cd terraform/environments/dev
terraform output

# 必要な出力:
# config_service_role_arn
# audit_bucket_name
# vpc_id / subnet_ids
```

## 作成するリソース一覧

### 1. AWS Config Recorder + Delivery Channel

**ファイル**: `terraform/modules/config/recorder.tf`

```hcl
# Config Recorder
resource "aws_config_configuration_recorder" "main" {
  name     = "csar-config-recorder"
  role_arn = var.config_service_role_arn

  recording_group {
    # 全リソースタイプを記録（対象を絞るとConfig Rulesが機能しないケースがある）
    all_supported                 = true
    include_global_resource_types = true  # IAMユーザーを含むため必須
  }
}

# Delivery Channel (設定スナップショット・変更通知の配信先)
resource "aws_config_delivery_channel" "main" {
  name           = "csar-config-delivery"
  s3_bucket_name = var.audit_bucket_name
  s3_key_prefix  = "config-snapshots"

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

# Recorder を有効化
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}
```

### 2. Config Rules — S3 系

**ファイル**: `terraform/modules/config/rules_s3.tf`

#### Rule 1: S3 Public Access 禁止

```hcl
resource "aws_config_config_rule" "s3_public_read_prohibited" {
  name = "csar-s3-bucket-public-read-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  # 変更時に即評価 (変更ドリブン評価)
  # このルールはS3バケット変更時にトリガーされる
  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "s3_bucket_sse_enabled" {
  name = "csar-s3-bucket-server-side-encryption-enabled"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
```

### 3. Config Rules — IAM 系

**ファイル**: `terraform/modules/config/rules_iam.tf`

```hcl
resource "aws_config_config_rule" "iam_user_mfa_enabled" {
  name = "csar-iam-user-mfa-enabled"

  source {
    owner             = "AWS"
    source_identifier = "IAM_USER_MFA_ENABLED"
  }

  # IAMはグローバルリソースのためscopeなし (全IAMユーザーが対象)
  # 評価頻度: 定期的 (変更ドリブンではない)
  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "iam_no_inline_policy" {
  name = "csar-iam-user-no-policies-check"

  source {
    owner             = "AWS"
    source_identifier = "IAM_USER_NO_POLICIES_CHECK"
    # IAMユーザーへの直接ポリシーアタッチ禁止 (グループ/ロール経由が正しい)
  }

  scope {
    compliance_resource_types = ["AWS::IAM::User"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
```

### 4. Config Rules — EC2/Security Group 系

**ファイル**: `terraform/modules/config/rules_ec2.tf`

```hcl
resource "aws_config_config_rule" "restricted_ssh" {
  name = "csar-restricted-ssh"

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  # ポート22への0.0.0.0/0アクセスを禁止
  input_parameters = jsonencode({
    blockedPort1 = "22"
  })

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "restricted_rdp" {
  name = "csar-restricted-rdp"

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({
    blockedPort1 = "3389"
  })

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
```

### 5. Config Rules — RDS 系

**ファイル**: `terraform/modules/config/rules_rds.tf`

```hcl
resource "aws_config_config_rule" "rds_storage_encrypted" {
  name = "csar-rds-storage-encrypted"

  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }

  scope {
    compliance_resource_types = ["AWS::RDS::DBInstance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "rds_public_access_check" {
  name = "csar-rds-instance-public-access-check"

  source {
    owner             = "AWS"
    source_identifier = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
  }

  scope {
    compliance_resource_types = ["AWS::RDS::DBInstance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
```

### 6. EventBridge Rules (Config → Lambda ルーティング)

**ファイル**: `terraform/modules/config/eventbridge.tf`

Config Rulesが違反を検知したとき、`aws.config` ソースから `Config Rules Compliance Change` イベントが発行される。
これをEventBridgeでキャッチし、対応するLambdaへルーティングする。

```hcl
# S3修復ルール
resource "aws_cloudwatch_event_rule" "s3_noncompliant" {
  name        = "csar-config-s3-noncompliant"
  description = "S3 Config Rule非準拠をキャッチしてLambdaへ"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      configRuleName = [
        "csar-s3-bucket-public-read-prohibited",
        "csar-s3-bucket-server-side-encryption-enabled"
      ]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "s3_remediation_lambda" {
  rule      = aws_cloudwatch_event_rule.s3_noncompliant.name
  target_id = "csar-s3-remediation-lambda"
  arn       = var.s3_remediation_lambda_arn  # Phase4で設定

  # 失敗時のDLQへのルーティング
  dead_letter_config {
    arn = var.dlq_arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600  # 1時間以内のイベントのみ再試行
    maximum_retry_attempts       = 3
  }
}

# IAM修復ルール
resource "aws_cloudwatch_event_rule" "iam_noncompliant" {
  name        = "csar-config-iam-noncompliant"
  description = "IAM Config Rule非準拠をキャッチしてLambdaへ"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      configRuleName = [
        "csar-iam-user-mfa-enabled",
        "csar-iam-user-no-policies-check"
      ]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "iam_remediation_lambda" {
  rule      = aws_cloudwatch_event_rule.iam_noncompliant.name
  target_id = "csar-iam-remediation-lambda"
  arn       = var.iam_remediation_lambda_arn  # Phase4で設定

  dead_letter_config {
    arn = var.dlq_arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

# EC2/SG修復ルール
resource "aws_cloudwatch_event_rule" "sg_noncompliant" {
  name        = "csar-config-sg-noncompliant"
  description = "Security Group Config Rule非準拠をキャッチしてLambdaへ"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      configRuleName = [
        "csar-restricted-ssh",
        "csar-restricted-rdp"
      ]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "sg_remediation_lambda" {
  rule      = aws_cloudwatch_event_rule.sg_noncompliant.name
  target_id = "csar-sg-remediation-lambda"
  arn       = var.sg_remediation_lambda_arn  # Phase4で設定

  dead_letter_config {
    arn = var.dlq_arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

# RDS修復ルール
resource "aws_cloudwatch_event_rule" "rds_noncompliant" {
  name        = "csar-config-rds-noncompliant"
  description = "RDS Config Rule非準拠をキャッチしてLambdaへ"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      configRuleName = [
        "csar-rds-storage-encrypted",
        "csar-rds-instance-public-access-check"
      ]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "rds_remediation_lambda" {
  rule      = aws_cloudwatch_event_rule.rds_noncompliant.name
  target_id = "csar-rds-remediation-lambda"
  arn       = var.rds_remediation_lambda_arn  # Phase4で設定

  dead_letter_config {
    arn = var.dlq_arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}
```

**重要**: Phase4でLambda ARNが確定したら `var.xxx_remediation_lambda_arn` を実際のARNに更新し、`terraform apply` を再実行する。

### 7. ファイル構成

```
terraform/modules/config/
├── recorder.tf         # Config Recorder + Delivery Channel
├── rules_s3.tf         # S3系Config Rules
├── rules_iam.tf        # IAM系Config Rules
├── rules_ec2.tf        # EC2/SG系Config Rules
├── rules_rds.tf        # RDS系Config Rules
├── eventbridge.tf      # EventBridge Rules + Targets
├── variables.tf        # 外部からのinput
└── outputs.tf          # rule ARN等を出力
```

`terraform/modules/config/variables.tf`:
```hcl
variable "config_service_role_arn" { type = string }
variable "audit_bucket_name"       { type = string }
variable "dlq_arn"                 { type = string }
variable "eventbridge_invoke_role_arn" { type = string }

# Phase4で設定するLambda ARN (初回はnullで可)
variable "s3_remediation_lambda_arn"  { type = string; default = null }
variable "iam_remediation_lambda_arn" { type = string; default = null }
variable "sg_remediation_lambda_arn"  { type = string; default = null }
variable "rds_remediation_lambda_arn" { type = string; default = null }
```

`terraform/modules/config/outputs.tf`:
```hcl
output "s3_noncompliant_rule_name"   { value = aws_cloudwatch_event_rule.s3_noncompliant.name }
output "iam_noncompliant_rule_name"  { value = aws_cloudwatch_event_rule.iam_noncompliant.name }
output "sg_noncompliant_rule_name"   { value = aws_cloudwatch_event_rule.sg_noncompliant.name }
output "rds_noncompliant_rule_name"  { value = aws_cloudwatch_event_rule.rds_noncompliant.name }
output "config_rules" {
  value = {
    s3_public  = aws_config_config_rule.s3_public_read_prohibited.name
    s3_sse     = aws_config_config_rule.s3_bucket_sse_enabled.name
    iam_mfa    = aws_config_config_rule.iam_user_mfa_enabled.name
    iam_policy = aws_config_config_rule.iam_no_inline_policy.name
    ssh        = aws_config_config_rule.restricted_ssh.name
    rdp        = aws_config_config_rule.restricted_rdp.name
    rds_enc    = aws_config_config_rule.rds_storage_encrypted.name
    rds_pub    = aws_config_config_rule.rds_public_access_check.name
  }
}
```

### 8. 違反テスト用リソース作成スクリプト (後のテスト用に今作っておく)

`tests/integration/create_violation_s3.sh`:
```bash
#!/bin/bash
# S3 Public Access 違反を意図的に作成するスクリプト (テスト用)
# ⚠️ テスト後は必ず手動で修復 or 自動修復の確認後削除すること

set -euo pipefail

BUCKET_NAME="csar-test-violation-$(date +%s)"
REGION="ap-northeast-1"

echo "=== S3違反バケット作成: ${BUCKET_NAME} ==="

# バケット作成
aws s3api create-bucket \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --create-bucket-configuration LocationConstraint="${REGION}"

# Public Access Block を意図的に無効化 (違反状態)
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

echo "違反バケット作成完了: ${BUCKET_NAME}"
echo "Config Ruleが評価されるまで数分待つこと"
echo "手動でConfig Rule評価をトリガーする場合:"
echo "  aws configservice start-config-rules-evaluation --config-rule-names csar-s3-bucket-public-read-prohibited"
```

`tests/integration/create_violation_sg.sh`:
```bash
#!/bin/bash
# Security Group SSH 0.0.0.0/0 違反を作成するスクリプト (テスト用)

set -euo pipefail

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=csar-vpc" \
  --query "Vpcs[0].VpcId" --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name "csar-test-violation-sg-$(date +%s)" \
  --description "テスト用違反SG" \
  --vpc-id "${VPC_ID}" \
  --query "GroupId" --output text)

# SSH 0.0.0.0/0 を意図的に開放 (違反状態)
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

echo "違反SG作成完了: ${SG_ID}"
echo "Config Rule評価: aws configservice start-config-rules-evaluation --config-rule-names csar-restricted-ssh"
```

## 実行手順

```bash
# modules/configをmain.tfに追加してapply
cd terraform/environments/dev

# main.tfに以下を追加してからapply
# module "config" {
#   source                    = "../../modules/config"
#   config_service_role_arn   = module.iam.config_service_role_arn
#   audit_bucket_name         = module.audit.audit_bucket_name
#   dlq_arn                   = module.audit.dlq_arn
#   eventbridge_invoke_role_arn = module.iam.eventbridge_invoke_role_arn
# }

terraform plan -out=tfplan
terraform apply tfplan
```

## 完了確認

```bash
# Config Recorderが有効であること
aws configservice describe-configuration-recorder-status \
  --query "ConfigurationRecordersStatus[0].{Name:name,Recording:recording}"

# Config Rulesが存在すること (8ルール)
aws configservice describe-config-rules \
  --query "ConfigRules[?contains(ConfigRuleName,'csar')].{Name:ConfigRuleName,State:ConfigRuleState}"

# EventBridge Rulesが存在すること
aws events list-rules \
  --name-prefix "csar-config" \
  --query "Rules[].{Name:Name,State:State}"

# Config評価を手動トリガーしてNON_COMPLIANTリソースを確認
aws configservice start-config-rules-evaluation \
  --config-rule-names csar-s3-bucket-public-read-prohibited

# 数分後に結果確認
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name csar-s3-bucket-public-read-prohibited \
  --compliance-types NON_COMPLIANT
```

## 口頭説明チェック (Phase 2)

以下を見ずに説明できるか確認すること:

1. **Config RecorderとConfig Ruleの違い** — Recorderは「何を記録するか」、Ruleは「何を評価するか」の違いを説明できるか？`include_global_resource_types=true` がなぜIAMユーザーの検知に必要か？

2. **Config Ruleの評価タイミング2種** — 変更ドリブン（Scope指定あり）と定期評価（maximum_execution_frequency）の違いと使い分けを説明できるか？IAMユーザーMFAチェックが定期評価になっている理由は？

3. **EventBridgeのevent_patternの構造** — `source: ["aws.config"]`, `detail-type: ["Config Rules Compliance Change"]`, `detail.newEvaluationResult.complianceType: ["NON_COMPLIANT"]` の各フィールドの意味は？

4. **EventBridgeのretry_policyとDLQの役割分担** — `maximum_retry_attempts=3` の後で失敗したイベントはどこへ行くか？DLQのメッセージをどう処理するか？

5. **RDSの暗号化をインプレースで修復できない理由** — なぜRDS暗号化はスナップショット経由になるのか？技術的制約を説明できるか？