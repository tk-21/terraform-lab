# terraform/modules/monitoring/main.tf
#
# CloudWatch アラーム・ダッシュボード・SNS 通知の設定。

# ============================================================
# SNS トピック（アラーム通知先）
# ============================================================
resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ============================================================
# Lambda エラー率アラーム
# ============================================================
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = toset(var.lambda_function_names)

  alarm_name          = "${each.value}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda ${each.value} でエラーが多発しています"

  dimensions = {
    FunctionName = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ============================================================
# Lambda スロットリングアラーム
# ============================================================
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = toset(var.lambda_function_names)

  alarm_name          = "${each.value}-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Lambda ${each.value} でスロットリングが発生しています"

  dimensions = {
    FunctionName = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ============================================================
# API Gateway 5xx エラーアラーム
# ============================================================
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.prefix}-api-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "API Gateway で 5xx エラーが多発しています"

  dimensions = {
    ApiName = "${var.prefix}-api"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ============================================================
# CloudWatch ダッシュボード
# ============================================================
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Invocations"
          period = 300
          stat   = "Sum"
          metrics = [
            for fn in var.lambda_function_names :
            ["AWS/Lambda", "Invocations", "FunctionName", fn]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Errors"
          period = 300
          stat   = "Sum"
          metrics = [
            for fn in var.lambda_function_names :
            ["AWS/Lambda", "Errors", "FunctionName", fn]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway Requests"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", "${var.prefix}-api"],
            ["AWS/ApiGateway", "5XXError", "ApiName", "${var.prefix}-api"],
            ["AWS/ApiGateway", "4XXError", "ApiName", "${var.prefix}-api"],
          ]
        }
      },
    ]
  })
}
