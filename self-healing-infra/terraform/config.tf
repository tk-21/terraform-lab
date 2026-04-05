# AWS Config Recorder の有効化
resource "aws_config_configuration_recorder" "main" {
  name     = "security-recorder"
  role_arn = aws_iam_role.config_role.arn

  recording_group {
    all_supported  = false
    resource_types = ["AWS::EC2::SecurityGroup"]
  }
}

# S3バケット（Config履歴保存）
resource "aws_s3_bucket" "config_bucket" {
  bucket        = "config-remediation-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "config_bucket" {
  bucket = aws_s3_bucket.config_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config_bucket.arn
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config_bucket.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

# Config Recording を有効化（これがないと記録が始まらない）
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_config_delivery_channel" "main" {
  name           = "security-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config_bucket.bucket
  depends_on     = [aws_config_configuration_recorder.main]
}

# マネージドルール: SSH を 0.0.0.0/0 に開放したら違反
resource "aws_config_config_rule" "no_unrestricted_ssh" {
  name = "no-unrestricted-ssh"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

# EventBridge: 違反検知時にLambdaを起動
resource "aws_cloudwatch_event_rule" "config_violation" {
  name        = "config-sg-violation"
  description = "Trigger on Config Rule NON_COMPLIANT"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      configRuleName = ["no-unrestricted-ssh"]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.config_violation.name
  target_id = "RemediationLambda"
  arn       = aws_lambda_function.remediation.arn
}
