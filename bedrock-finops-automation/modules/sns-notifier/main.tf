# ============================================================
# modules/sns-notifier
# 月次コストレポートをSNS経由でEmail通知する Lambda
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# SNS Topic
# ============================================================

resource "aws_sns_topic" "cost_report" {
  name = "${var.project_name}-cost-report-${var.environment}"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Email購読者
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.email_addresses)

  topic_arn = aws_sns_topic.cost_report.arn
  protocol  = "email"
  endpoint  = each.value
}

# ============================================================
# IAM Role
# ============================================================

resource "aws_iam_role" "sns_notifier" {
  name = "${var.project_name}-sns-notifier-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
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

resource "aws_iam_role_policy" "sns_notifier" {
  name = "${var.project_name}-sns-notifier-policy-${var.environment}"
  role = aws_iam_role.sns_notifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # SNS Publish: cost_report topic のみ
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.cost_report.arn]
      },
      # DynamoDB: 最終ステータス更新
      {
        Sid      = "DynamoDBFinalUpdate"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [var.dynamodb_table_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sns_notifier_basic_execution" {
  role       = aws_iam_role.sns_notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================
# CloudWatch Logs Group
# ============================================================

resource "aws_cloudwatch_log_group" "sns_notifier" {
  name              = "/aws/lambda/${var.project_name}-sns-notifier-${var.environment}"
  retention_in_days = 30
}

# ============================================================
# Lambda Function
# ============================================================

data "archive_file" "sns_notifier" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/sns_notifier.zip"
}

resource "aws_lambda_function" "sns_notifier" {
  function_name = "${var.project_name}-sns-notifier-${var.environment}"
  role          = aws_iam_role.sns_notifier.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout

  filename         = data.archive_file.sns_notifier.output_path
  source_code_hash = data.archive_file.sns_notifier.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      SNS_TOPIC_ARN       = aws_sns_topic.cost_report.arn
      ENVIRONMENT         = var.environment
      PROJECT_NAME        = var.project_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.sns_notifier,
    aws_iam_role_policy_attachment.sns_notifier_basic_execution,
  ]
}
