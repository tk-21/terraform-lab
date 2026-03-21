locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ---------------------------------------------------------------------------
# SNS Alert Topic
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms
# ---------------------------------------------------------------------------

# アラーム1: Kinesis コンシューマー遅延（Firehose がどれだけ遅れているか）
# GetRecords.IteratorAgeMilliseconds が大きいほど Firehose の S3 到達が遅れている
resource "aws_cloudwatch_metric_alarm" "kinesis_iterator_age" {
  alarm_name          = "${local.name_prefix}-kds-iterator-age-high"
  alarm_description   = "Kinesis consumer lag > 5 minutes. Firehose may be falling behind."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "GetRecords.IteratorAgeMilliseconds"
  namespace           = "AWS/Kinesis"
  period              = 300
  statistic           = "Maximum"
  threshold           = 300000 # 5 分 (ms)
  treat_missing_data  = "notBreaching"

  dimensions = {
    StreamName = var.kinesis_stream_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# アラーム2: Firehose S3 配信失敗率
resource "aws_cloudwatch_metric_alarm" "firehose_delivery_failures" {
  alarm_name          = "${local.name_prefix}-firehose-delivery-failures"
  alarm_description   = "Firehose failed to deliver records to S3."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DeliveryToS3.DataFreshness"
  namespace           = "AWS/Firehose"
  period              = 300
  statistic           = "Maximum"
  threshold           = 900 # 15 分
  treat_missing_data  = "notBreaching"

  dimensions = {
    DeliveryStreamName = var.firehose_stream_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# アラーム3: Firehose 変換 Lambda エラー
resource "aws_cloudwatch_metric_alarm" "transform_lambda_errors" {
  alarm_name          = "${local.name_prefix}-transform-lambda-errors"
  alarm_description   = "Firehose transformation Lambda errors detected."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.transform_lambda_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${local.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # ---- 行 1: タイトル ----
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# Streaming Analytics Pipeline — ${var.project} (${var.environment})"
        }
      },

      # ---- 行 2: Kinesis ----
      {
        type   = "text"
        x      = 0
        y      = 1
        width  = 24
        height = 1
        properties = { markdown = "## Kinesis Data Streams" }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "KDS IncomingRecords"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Kinesis", "IncomingRecords",
            "StreamName", var.kinesis_stream_name,
            { stat = "Sum", period = 60 }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "KDS IteratorAgeMilliseconds (Consumer Lag)"
          view   = "timeSeries"
          region = "ap-northeast-1"
          annotations = {
            horizontal = [{ label = "5 min threshold", value = 300000, color = "#ff6961" }]
          }
          metrics = [[
            "AWS/Kinesis", "GetRecords.IteratorAgeMilliseconds",
            "StreamName", var.kinesis_stream_name,
            { stat = "Maximum", period = 60 }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "KDS PutRecord Success"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Kinesis", "PutRecord.Success",
            "StreamName", var.kinesis_stream_name,
            { stat = "Average", period = 60 }
          ]]
        }
      },

      # ---- 行 3: Firehose ----
      {
        type   = "text"
        x      = 0
        y      = 8
        width  = 24
        height = 1
        properties = { markdown = "## Amazon Data Firehose" }
      },
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 8
        height = 6
        properties = {
          title  = "Firehose IncomingRecords"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Firehose", "IncomingRecords",
            "DeliveryStreamName", var.firehose_stream_name,
            { stat = "Sum", period = 60 }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 9
        width  = 8
        height = 6
        properties = {
          title  = "Firehose DataFreshness (S3 到達遅延)"
          view   = "timeSeries"
          region = "ap-northeast-1"
          annotations = {
            horizontal = [{ label = "15 min threshold", value = 900, color = "#ff6961" }]
          }
          metrics = [[
            "AWS/Firehose", "DeliveryToS3.DataFreshness",
            "DeliveryStreamName", var.firehose_stream_name,
            { stat = "Maximum", period = 60 }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 9
        width  = 8
        height = 6
        properties = {
          title  = "Firehose DeliveryToS3.Success"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Firehose", "DeliveryToS3.Success",
            "DeliveryStreamName", var.firehose_stream_name,
            { stat = "Average", period = 60 }
          ]]
        }
      },

      # ---- 行 4: Lambda (変換) ----
      {
        type   = "text"
        x      = 0
        y      = 15
        width  = 24
        height = 1
        properties = { markdown = "## Firehose Transformation Lambda" }
      },
      {
        type   = "metric"
        x      = 0
        y      = 16
        width  = 8
        height = 6
        properties = {
          title  = "Lambda Invocations"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Lambda", "Invocations",
            "FunctionName", var.transform_lambda_name,
            { stat = "Sum", period = 60 }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 16
        width  = 8
        height = 6
        properties = {
          title  = "Lambda Errors"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Lambda", "Errors",
            "FunctionName", var.transform_lambda_name,
            { stat = "Sum", period = 60, color = "#ff6961" }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 16
        width  = 8
        height = 6
        properties = {
          title  = "Lambda Duration (ms)"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Lambda", "Duration",
            "FunctionName", var.transform_lambda_name,
            { stat = "p99", period = 60, label = "p99" }
          ]]
        }
      },

      # ---- 行 5: Athena ----
      {
        type   = "text"
        x      = 0
        y      = 22
        width  = 24
        height = 1
        properties = { markdown = "## Amazon Athena" }
      },
      {
        type   = "metric"
        x      = 0
        y      = 23
        width  = 12
        height = 6
        properties = {
          title  = "Athena ProcessedBytes (スキャン量)"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Athena", "ProcessedBytes",
            "WorkGroup", var.athena_workgroup_name,
            { stat = "Sum", period = 300 }
          ]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 23
        width  = 12
        height = 6
        properties = {
          title  = "Athena EngineExecutionTime (ms)"
          view   = "timeSeries"
          region = "ap-northeast-1"
          metrics = [[
            "AWS/Athena", "EngineExecutionTime",
            "WorkGroup", var.athena_workgroup_name,
            { stat = "p99", period = 300 }
          ]]
        }
      }
    ]
  })
}
