# HTMLレポートをPresigned URLで配布するためのバケット
resource "aws_s3_bucket" "reports" {
  bucket = "${var.prefix}-reports-${var.account_id}"

  tags = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "archive-and-delete"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Agent実行履歴とHuman-in-the-loop承認状態を管理するテーブル
resource "aws_dynamodb_table" "execution_history" {
  name         = "${var.prefix}-execution-history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "execution_id"
  range_key    = "timestamp"

  attribute {
    name = "execution_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    projection_type = "ALL"
  }

  tags = var.common_tags
}

# Remediationの実行前に人間承認を記録するテーブル。TTLで未承認リクエストを自動破棄
resource "aws_dynamodb_table" "approval_requests" {
  name         = "${var.prefix}-approval-requests"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = var.common_tags
}

resource "aws_ssm_parameter" "chatwork_room_id" {
  name  = "/bmao/chatwork/room_id"
  type  = "SecureString"
  value = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = var.common_tags
}

resource "aws_ssm_parameter" "chatwork_api_token" {
  name  = "/bmao/chatwork/api_token"
  type  = "SecureString"
  value = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }

  tags = var.common_tags
}

resource "aws_ssm_parameter" "cost_threshold_usd" {
  name  = "/bmao/config/cost_threshold_usd"
  type  = "String"
  value = "50"

  lifecycle {
    ignore_changes = [value]
  }

  tags = var.common_tags
}

# 全LambdaがChatwork通知・DynamoDB記録・S3レポート保存に必要な最小権限
resource "aws_iam_role" "lambda_base" {
  name = "${var.prefix}-lambda-base-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_base_execution" {
  role       = aws_iam_role.lambda_base.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_base_xray" {
  role       = aws_iam_role.lambda_base.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "lambda_base_inline" {
  name = "${var.prefix}-lambda-base-inline"
  role = aws_iam_role.lambda_base.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/bmao/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.execution_history.arn,
          aws_dynamodb_table.approval_requests.arn,
          "${aws_dynamodb_table.execution_history.arn}/index/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${var.prefix}-reports-*/*"
      }
    ]
  })
}

# SupervisorがSub-agentを呼び出すための権限。エージェントエイリアスARNを限定
resource "aws_iam_role" "supervisor_agent" {
  name = "${var.prefix}-supervisor-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "supervisor_agent_inline" {
  name = "${var.prefix}-supervisor-agent-inline"
  role = aws_iam_role.supervisor_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeAgent"
        Resource = "arn:aws:bedrock:ap-northeast-1:*:agent-alias/*"
      },
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-7-sonnet-20250219-v1:0"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda_incident_investigator" {
  name              = "/aws/lambda/bmao-incident-investigator"
  retention_in_days = 14

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "lambda_cost_optimizer" {
  name              = "/aws/lambda/bmao-cost-optimizer"
  retention_in_days = 14

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "lambda_remediation" {
  name              = "/aws/lambda/bmao-remediation"
  retention_in_days = 14

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "lambda_reporter" {
  name              = "/aws/lambda/bmao-reporter"
  retention_in_days = 14

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "stepfunctions_orchestrator" {
  name              = "/aws/stepfunctions/bmao-ops-orchestrator"
  retention_in_days = 14

  tags = var.common_tags
}
