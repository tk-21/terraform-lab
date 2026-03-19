locals {
  name_prefix        = "${var.project}-${var.environment}"
  state_machine_name = "${local.name_prefix}-ai-pipeline"
}

# -----------------------------------------------------------------
# CloudWatch Log Group for Step Functions execution logs
# -----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.state_machine_name}"
  retention_in_days = var.log_retention_days
}

# -----------------------------------------------------------------
# IAM Role for Step Functions
# Bedrock / DynamoDB / SNS を SDK 統合で呼ぶための権限
# -----------------------------------------------------------------
resource "aws_iam_role" "sfn" {
  name = "${local.name_prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role_policy" "sfn" {
  name = "${local.name_prefix}-sfn-policy"
  role = aws_iam_role.sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Bedrock SDK 統合: InvokeModel
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = [
          "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
          "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0",
        ]
      },
      # DynamoDB SDK 統合: UpdateItem
      {
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem",
          "dynamodb:PutItem",
        ]
        Resource = var.jobs_table_arn
      },
      # SNS SDK 統合: Publish
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.notification_topic_arn
      },
      # CloudWatch Logs: 実行ログの書き込み
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:CreateLogStream",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
      # X-Ray トレーシング
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------
# Step Functions State Machine
# state_machine.asl.json.tftpl を templatefile() で読み込み
# DynamoDB テーブル名・SNS トピック ARN を注入する
# -----------------------------------------------------------------
resource "aws_sfn_state_machine" "ai_pipeline" {
  name     = local.state_machine_name
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD" # 監査ログが残る Standard Workflow を使用

  definition = templatefile("${path.module}/state_machine.asl.json.tftpl", {
    jobs_table_name        = var.jobs_table_name
    notification_topic_arn = var.notification_topic_arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL" # SUCCEEDED / FAILED / ABORTED / TIMED_OUT すべて記録
  }

  tracing_configuration {
    enabled = true
  }

  tags = {
    Name = local.state_machine_name
  }

  depends_on = [aws_cloudwatch_log_group.sfn]
}
