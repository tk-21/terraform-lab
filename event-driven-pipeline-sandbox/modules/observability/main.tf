locals {
  name_prefix = "${var.project}-${var.environment}"
}

# -----------------------------------------------------------------
# X-Ray Group（Lambda + Step Functions のトレースをフィルタ）
# -----------------------------------------------------------------
resource "aws_xray_group" "pipeline" {
  group_name        = "${local.name_prefix}-pipeline"
  filter_expression = "service(\"${var.dispatcher_function_name}\") OR service(\"${var.stream_processor_function_name}\")"

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }
}

# -----------------------------------------------------------------
# CloudWatch Alarms
# -----------------------------------------------------------------

# 1. DLQ にメッセージが蓄積した場合（メッセージ処理の繰り返し失敗）
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.name_prefix}-dlq-messages"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.dlq_alarm_threshold
  alarm_description   = "Messages accumulating in DLQ - dispatcher is failing repeatedly"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.dlq_name
  }

  alarm_actions = [var.alert_topic_arn]
  ok_actions    = [var.alert_topic_arn]
}

# 2. Dispatcher Lambda エラー率
resource "aws_cloudwatch_metric_alarm" "dispatcher_errors" {
  alarm_name          = "${local.name_prefix}-dispatcher-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = var.lambda_error_threshold
  alarm_description   = "Dispatcher Lambda is throwing errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.dispatcher_function_name
  }

  alarm_actions = [var.alert_topic_arn]
}

# 3. Step Functions 実行失敗
resource "aws_cloudwatch_metric_alarm" "sfn_executions_failed" {
  alarm_name          = "${local.name_prefix}-sfn-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Step Functions executions are failing"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = var.state_machine_arn
  }

  alarm_actions = [var.alert_topic_arn]
}

# 4. SQS キューの滞留（処理が追いつかない場合）
resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  alarm_name          = "${local.name_prefix}-queue-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 100
  alarm_description   = "Input queue depth is high - processing may be falling behind"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.input_queue_name
  }

  alarm_actions = [var.alert_topic_arn]
}

# -----------------------------------------------------------------
# CloudWatch Dashboard
# -----------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${local.name_prefix}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      # --- タイトル ---
      {
        type   = "text"
        x      = 0; y = 0; width = 24; height = 2
        properties = {
          markdown = "# Event-Driven AI Pipeline Dashboard\nSQS → Dispatcher Lambda → Step Functions → Bedrock"
        }
      },

      # --- SQS メトリクス ---
      {
        type   = "metric"
        x      = 0; y = 2; width = 8; height = 6
        properties = {
          title  = "SQS Input Queue - Messages"
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.input_queue_name, { label = "Queued" }],
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", var.input_queue_name, { label = "Sent (5min)" }],
            ["AWS/SQS", "NumberOfMessagesDeleted", "QueueName", var.input_queue_name, { label = "Deleted (processed)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8; y = 2; width = 8; height = 6
        properties = {
          title  = "SQS DLQ - Dead Letter Messages"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.dlq_name, { color = "#d62728", label = "DLQ Depth" }],
          ]
        }
      },

      # --- Step Functions ---
      {
        type   = "metric"
        x      = 16; y = 2; width = 8; height = 6
        properties = {
          title  = "Step Functions Executions"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", var.state_machine_arn, { label = "Started" }],
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", var.state_machine_arn, { label = "Succeeded", color = "#2ca02c" }],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", var.state_machine_arn, { label = "Failed", color = "#d62728" }],
          ]
        }
      },

      # --- Lambda Invocations ---
      {
        type   = "metric"
        x      = 0; y = 8; width = 12; height = 6
        properties = {
          title  = "Lambda - Invocations"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.dispatcher_function_name, { label = "Dispatcher" }],
            ["AWS/Lambda", "Invocations", "FunctionName", var.stream_processor_function_name, { label = "StreamProcessor" }],
            ["AWS/Lambda", "Invocations", "FunctionName", var.dlq_handler_function_name, { label = "DLQHandler" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12; y = 8; width = 12; height = 6
        properties = {
          title  = "Lambda - Errors & Throttles"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", var.dispatcher_function_name, { label = "Dispatcher Errors", color = "#d62728" }],
            ["AWS/Lambda", "Errors", "FunctionName", var.stream_processor_function_name, { label = "StreamProcessor Errors", color = "#ff7f0e" }],
            ["AWS/Lambda", "Throttles", "FunctionName", var.dispatcher_function_name, { label = "Dispatcher Throttles", color = "#9467bd" }],
          ]
        }
      },

      # --- DynamoDB ---
      {
        type   = "metric"
        x      = 0; y = 14; width = 12; height = 6
        properties = {
          title  = "DynamoDB - Request Latency (ms)"
          period = 300
          stat   = "p99"
          metrics = [
            ["AWS/DynamoDB", "SuccessfulRequestLatency", "TableName", var.jobs_table_name, "Operation", "PutItem", { label = "PutItem p99" }],
            ["AWS/DynamoDB", "SuccessfulRequestLatency", "TableName", var.jobs_table_name, "Operation", "UpdateItem", { label = "UpdateItem p99" }],
            ["AWS/DynamoDB", "SuccessfulRequestLatency", "TableName", var.jobs_table_name, "Operation", "GetItem", { label = "GetItem p99" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12; y = 14; width = 12; height = 6
        properties = {
          title  = "Step Functions - Execution Duration (ms)"
          period = 300
          stat   = "p95"
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", var.state_machine_arn, { label = "Duration p95" }],
          ]
        }
      },
    ]
  })
}
