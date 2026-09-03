# ===== S3 修復ルール =====
# S3 Config Rule が NON_COMPLIANT を検知した際にS3修復Lambdaへルーティングする
resource "aws_cloudwatch_event_rule" "s3_noncompliant" {
  name        = "csar-config-s3-noncompliant"
  description = "S3 Config Rule非準拠をキャッチしてLambdaへルーティングする"

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
  arn       = var.s3_remediation_lambda_arn

  # EventBridgeからLambdaを実行するためのロール
  role_arn = var.eventbridge_invoke_role_arn

  # 3回リトライ後も失敗した場合はDLQへ転送する
  dead_letter_config {
    arn = var.dlq_arn
  }

  retry_policy {
    # 1時間以内のイベントのみ再試行する (古いイベントは修復済みの可能性が高い)
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

# ===== IAM 修復ルール =====
resource "aws_cloudwatch_event_rule" "iam_noncompliant" {
  name        = "csar-config-iam-noncompliant"
  description = "IAM Config Rule非準拠をキャッチしてLambdaへルーティングする"

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
  arn       = var.iam_remediation_lambda_arn

  role_arn = var.eventbridge_invoke_role_arn

  dead_letter_config {
    arn = var.dlq_arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

# ===== EC2/Security Group 修復ルール =====
resource "aws_cloudwatch_event_rule" "sg_noncompliant" {
  name        = "csar-config-sg-noncompliant"
  description = "Security Group Config Rule非準拠をキャッチしてLambdaへルーティングする"

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
  arn       = var.sg_remediation_lambda_arn

  role_arn = var.eventbridge_invoke_role_arn

  dead_letter_config {
    arn = var.dlq_arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

# ===== RDS 修復ルール =====
resource "aws_cloudwatch_event_rule" "rds_noncompliant" {
  name        = "csar-config-rds-noncompliant"
  description = "RDS Config Rule非準拠をキャッチしてLambdaへルーティングする"

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
  arn       = var.rds_remediation_lambda_arn

  role_arn = var.eventbridge_invoke_role_arn

  dead_letter_config {
    arn = var.dlq_arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}
