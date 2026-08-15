locals {
  name_prefix = "${var.project}-${var.environment}"

  # X-Ray Group 名は最大32文字。先頭の可読部分とハッシュで識別性・一意性を両立する。
  xray_group_name = "${substr(local.name_prefix, 0, 23)}-${substr(sha256(local.name_prefix), 0, 8)}"
}

data "aws_region" "current" {}

# -----------------------------------------------------------------
# X-Ray Group: Lambda トレース
# -----------------------------------------------------------------
resource "aws_xray_group" "lambdas" {
  group_name        = local.xray_group_name
  filter_expression = "annotation.project = \"${var.project}\""

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-xray-group"
  }
}

# -----------------------------------------------------------------
# CloudWatch Metric Filter: Bedrock InvokeModel 呼び出し数
# CloudTrail ログから bedrock:InvokeModel イベントを抽出
# -----------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "bedrock_invoke" {
  name           = "${local.name_prefix}-bedrock-invoke-count"
  log_group_name = var.cloudtrail_log_group
  pattern        = "{ $.eventName = \"InvokeModel\" }"

  metric_transformation {
    name          = "BedrockInvokeCount"
    namespace     = "${var.project}/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "bedrock_invoke_stream" {
  name           = "${local.name_prefix}-bedrock-invoke-stream-count"
  log_group_name = var.cloudtrail_log_group
  pattern        = "{ $.eventName = \"InvokeModelWithResponseStream\" }"

  metric_transformation {
    name          = "BedrockInvokeStreamCount"
    namespace     = "${var.project}/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# -----------------------------------------------------------------
# CloudWatch Alarms
# -----------------------------------------------------------------

# Router Lambda エラーアラーム
resource "aws_cloudwatch_metric_alarm" "router_lambda_errors" {
  alarm_name          = "${local.name_prefix}-router-lambda-errors"
  alarm_description   = "Router Lambda function error count exceeded threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = var.lambda_error_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.router_lambda_name
  }

  alarm_actions = [var.alert_topic_arn]
  ok_actions    = [var.alert_topic_arn]

  tags = {
    Name = "${local.name_prefix}-router-lambda-errors-alarm"
  }
}

# Cost Controller Lambda エラーアラーム
resource "aws_cloudwatch_metric_alarm" "cost_controller_errors" {
  alarm_name          = "${local.name_prefix}-cost-controller-errors"
  alarm_description   = "Cost controller Lambda function error count exceeded threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = var.lambda_error_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.cost_controller_lambda_name
  }

  alarm_actions = [var.alert_topic_arn]
  ok_actions    = [var.alert_topic_arn]

  tags = {
    Name = "${local.name_prefix}-cost-controller-errors-alarm"
  }
}

# API Gateway 5xx エラーアラーム
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name_prefix}-api-5xx-errors"
  alarm_description   = "API Gateway 5xx error count exceeded threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = var.api_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_id
  }

  alarm_actions = [var.alert_topic_arn]
  ok_actions    = [var.alert_topic_arn]

  tags = {
    Name = "${local.name_prefix}-api-5xx-alarm"
  }
}

# -----------------------------------------------------------------
# CloudWatch Dashboard
# -----------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # ---- Row 1: API Gateway ----
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "API Gateway - Requests & Errors"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", var.api_id, { label = "Total Requests", stat = "Sum" }],
            ["AWS/ApiGateway", "4XXError", "ApiId", var.api_id, { label = "4xx Errors", stat = "Sum", color = "#ff7f0e" }],
            ["AWS/ApiGateway", "5XXError", "ApiId", var.api_id, { label = "5xx Errors", stat = "Sum", color = "#d62728" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "API Gateway - Latency (p50/p99)"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { label = "p50", stat = "p50" }],
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { label = "p99", stat = "p99", color = "#d62728" }],
          ]
          period = 300
          view   = "timeSeries"
          yAxis  = { left = { label = "ms" } }
        }
      },
      # ---- Row 1 右: Bedrock 呼び出し数 ----
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Bedrock - InvokeModel Calls"
          region = data.aws_region.current.name
          metrics = [
            ["${var.project}/${var.environment}", "BedrockInvokeCount", { label = "InvokeModel", stat = "Sum" }],
            ["${var.project}/${var.environment}", "BedrockInvokeStreamCount", { label = "InvokeStream", stat = "Sum" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      # ---- Row 2: Lambda ----
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Router Lambda - Invocations & Errors"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.router_lambda_name, { label = "Invocations", stat = "Sum" }],
            ["AWS/Lambda", "Errors", "FunctionName", var.router_lambda_name, { label = "Errors", stat = "Sum", color = "#d62728" }],
            ["AWS/Lambda", "Throttles", "FunctionName", var.router_lambda_name, { label = "Throttles", stat = "Sum", color = "#ff7f0e" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Action Handler Lambda - Invocations & Errors"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.action_handler_lambda_name, { label = "Invocations", stat = "Sum" }],
            ["AWS/Lambda", "Errors", "FunctionName", var.action_handler_lambda_name, { label = "Errors", stat = "Sum", color = "#d62728" }],
            ["AWS/Lambda", "Throttles", "FunctionName", var.action_handler_lambda_name, { label = "Throttles", stat = "Sum", color = "#ff7f0e" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Cost Controller Lambda - Invocations & Errors"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.cost_controller_lambda_name, { label = "Invocations", stat = "Sum" }],
            ["AWS/Lambda", "Errors", "FunctionName", var.cost_controller_lambda_name, { label = "Errors", stat = "Sum", color = "#d62728" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      # ---- Row 3: DynamoDB ----
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB - Tenant Table Read/Write"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.tenant_table_name, { label = "Read CU", stat = "Sum" }],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.tenant_table_name, { label = "Write CU", stat = "Sum" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB - Usage Table Read/Write"
          region = data.aws_region.current.name
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.usage_table_name, { label = "Read CU", stat = "Sum" }],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.usage_table_name, { label = "Write CU", stat = "Sum" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      # ---- Row 4: Alarm Status ----
      {
        type   = "alarm"
        x      = 0
        y      = 18
        width  = 24
        height = 3
        properties = {
          title = "Alarm Status"
          alarms = [
            aws_cloudwatch_metric_alarm.router_lambda_errors.arn,
            aws_cloudwatch_metric_alarm.cost_controller_errors.arn,
            aws_cloudwatch_metric_alarm.api_5xx.arn,
          ]
        }
      }
    ]
  })
}
