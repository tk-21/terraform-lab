resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.project}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Step Functions 実行結果・実行時間
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Step Functions - 実行結果"
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", var.state_machine_arn],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", var.state_machine_arn],
            ["AWS/States", "ExecutionsTimedOut", "StateMachineArn", var.state_machine_arn]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Step Functions - 実行時間 (ms)"
          period = 300
          stat   = "Average"
          view   = "timeSeries"
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", var.state_machine_arn]
          ]
        }
      },
      # Row 2: SQS メッセージ数
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "SQS - メッセージ数"
          period = 60
          stat   = "Maximum"
          view   = "timeSeries"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.orders_queue_name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.orders_dlq_name],
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", var.orders_queue_name],
            ["AWS/SQS", "NumberOfMessagesDeleted", "QueueName", var.orders_queue_name]
          ]
        }
      },
      # Row 3: Lambda エラー率
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Lambda - エラー率"
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", var.inventory_check_function],
            ["AWS/Lambda", "Errors", "FunctionName", var.notification_function],
            ["AWS/Lambda", "Errors", "FunctionName", var.dlq_reprocessor_function]
          ]
        }
      },
      # Row 4: ECS タスク実行状況
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "ECS - タスク実行"
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["ECS/ContainerInsights", "TaskCount", "ClusterName", var.ecs_cluster_name],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.ecs_cluster_name]
          ]
        }
      },
      # Row 5: カスタムメトリクス (業務 KPI)
      {
        type   = "metric"
        x      = 0
        y      = 24
        width  = 24
        height = 6
        properties = {
          title  = "カスタムメトリクス - 業務KPI"
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["OrderPipeline", "InventoryCheckSuccess", "service", "inventory-check"],
            ["OrderPipeline", "InventoryShortage", "service", "inventory-check"],
            ["OrderPipeline", "NotificationSent", "service", "notification"],
            ["OrderPipeline", "CompensationExecuted", "service", "dlq-reprocessor"],
            ["OrderPipeline", "CompensationFailed", "service", "dlq-reprocessor"]
          ]
        }
      }
    ]
  })
}

# アラーム: Step Functions 失敗数
# なぜ: 5分間に3回以上失敗したら異常と判断し早期検知する
resource "aws_cloudwatch_metric_alarm" "sfn_failures" {
  alarm_name          = "${var.project}-sfn-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 3

  dimensions = {
    StateMachineArn = var.state_machine_arn
  }

  alarm_description = "Step Functions の実行失敗が多発しています"
  tags              = var.common_tags
}

# アラーム: 在庫確認 Lambda エラー率
resource "aws_cloudwatch_metric_alarm" "inventory_errors" {
  alarm_name          = "${var.project}-inventory-check-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5

  dimensions = {
    FunctionName = var.inventory_check_function
  }

  alarm_description = "在庫確認 Lambda のエラーが増加しています"
  tags              = var.common_tags
}

# アラーム: DLQ メッセージ数
# なぜ: DLQ へのメッセージ到達は補償処理が必要なことを示すため即時検知する
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.project}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0

  dimensions = {
    QueueName = var.orders_dlq_name
  }

  alarm_description = "DLQ にメッセージが到達しました。補償処理を確認してください"
  tags              = var.common_tags
}
