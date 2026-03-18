locals {
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------
# Lambda パッケージング
# -----------------------------------------------------------------
data "archive_file" "cost_controller" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/cost_controller.zip"
}

# -----------------------------------------------------------------
# SNS Topic: 予算アラート通知
# -----------------------------------------------------------------
resource "aws_sns_topic" "budget_alerts" {
  name = "${local.name_prefix}-budget-alerts"

  tags = {
    Name = "${local.name_prefix}-budget-alerts"
  }
}

# AWS Budgets / EventBridge が Publish できるようにするトピックポリシー
resource "aws_sns_topic_policy" "budget_alerts" {
  arn = aws_sns_topic.budget_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBudgetsPublish"
        Effect = "Allow"
        Principal = { Service = "budgets.amazonaws.com" }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.budget_alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid    = "AllowLambdaPublish"
        Effect = "Allow"
        Principal = { AWS = aws_iam_role.cost_controller.arn }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.budget_alerts.arn
      }
    ]
  })
}

# メール通知（alert_email が設定されている場合のみ）
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------
# AWS Budgets: 月額 $30 上限アラート
# -----------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 80% 到達でアラート
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  # 100% 到達でアラート
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }
}

# -----------------------------------------------------------------
# CloudWatch Log Group
# -----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cost_controller" {
  name              = "/aws/lambda/${local.name_prefix}-cost-controller"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-cost-controller-logs"
  }
}

# -----------------------------------------------------------------
# IAM Role for Cost Controller Lambda
# -----------------------------------------------------------------
resource "aws_iam_role" "cost_controller" {
  name = "${local.name_prefix}-cost-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = { Name = "${local.name_prefix}-cost-controller-role" }
}

resource "aws_iam_policy" "cost_controller" {
  name = "${local.name_prefix}-cost-controller-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.cost_controller.arn}:*"
      },
      {
        Sid    = "AllowXRay"
        Effect = "Allow"
        Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
      {
        Sid    = "AllowTenantScan"
        Effect = "Allow"
        Action = ["dynamodb:Scan"]
        Resource = [var.tenant_table_arn]
      },
      {
        Sid    = "AllowUsageRead"
        Effect = "Allow"
        Action = ["dynamodb:GetItem"]
        Resource = [var.usage_table_arn]
      },
      {
        Sid    = "AllowSNSPublish"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [aws_sns_topic.budget_alerts.arn]
      }
    ]
  })

  tags = { Name = "${local.name_prefix}-cost-controller-policy" }
}

resource "aws_iam_role_policy_attachment" "cost_controller" {
  role       = aws_iam_role.cost_controller.name
  policy_arn = aws_iam_policy.cost_controller.arn
}

# -----------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------
resource "aws_lambda_function" "cost_controller" {
  function_name    = "${local.name_prefix}-cost-controller"
  description      = "Monitors per-tenant token budgets and publishes alerts via SNS"
  role             = aws_iam_role.cost_controller.arn
  handler          = "index.lambda_handler"
  runtime          = "python3.12"
  memory_size      = var.lambda_memory_mb
  timeout          = 60
  filename         = data.archive_file.cost_controller.output_path
  source_code_hash = data.archive_file.cost_controller.output_base64sha256

  environment {
    variables = {
      TENANT_TABLE    = var.tenant_table_name
      USAGE_TABLE     = var.usage_table_name
      ALERT_TOPIC_ARN = aws_sns_topic.budget_alerts.arn
      WARN_PERCENT    = tostring(var.warn_percent)
    }
  }

  tracing_config { mode = "Active" }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.cost_controller.name
  }

  tags = { Name = "${local.name_prefix}-cost-controller" }

  depends_on = [
    aws_iam_role_policy_attachment.cost_controller,
    aws_cloudwatch_log_group.cost_controller,
  ]
}

# -----------------------------------------------------------------
# EventBridge: 定期実行スケジュール
# -----------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "cost_check" {
  name                = "${local.name_prefix}-cost-check"
  description         = "Periodically trigger cost controller Lambda"
  schedule_expression = var.schedule_expression

  tags = { Name = "${local.name_prefix}-cost-check" }
}

resource "aws_cloudwatch_event_target" "cost_check" {
  rule      = aws_cloudwatch_event_rule.cost_check.name
  target_id = "CostControllerLambda"
  arn       = aws_lambda_function.cost_controller.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_controller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cost_check.arn
}
