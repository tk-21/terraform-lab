resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # ---- 行1: タイトル ----
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "## Global Accelerator & ALB"
        }
      },
      # ---- 行1左: Global Accelerator メトリクス ----
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 12
        height = 6
        properties = {
          title = "Global Accelerator - Connections & Throughput"
          metrics = [
            ["AWS/GlobalAccelerator", "NewFlowCount", "Accelerator", "${var.name_prefix}-accelerator", { "region" : "us-east-1" }],
            ["AWS/GlobalAccelerator", "ProcessedByteCount", "Accelerator", "${var.name_prefix}-accelerator", { "region" : "us-east-1", "yAxis" : "right" }]
          ]
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      # ---- 行1右: ALB メトリクス ----
      {
        type   = "metric"
        x      = 12
        y      = 1
        width  = 12
        height = 6
        properties = {
          title = "ALB - Requests & Errors & Latency"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "${var.alb_arn_suffix}"],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", "${var.alb_arn_suffix}", { "color" : "#d62728" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${var.alb_arn_suffix}", { "stat" : "p99", "yAxis" : "right" }]
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      # ---- 行2: タイトル ----
      {
        type   = "text"
        x      = 0
        y      = 7
        width  = 24
        height = 1
        properties = {
          markdown = "## Lambda & Kinesis Firehose"
        }
      },
      # ---- 行2左: Lambda Receiver ----
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 8
        height = 6
        properties = {
          title = "Lambda Receiver"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.lambda_receiver_function_name}"],
            ["AWS/Lambda", "Errors", "FunctionName", "${var.lambda_receiver_function_name}", { "color" : "#d62728" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${var.lambda_receiver_function_name}", { "stat" : "p99", "yAxis" : "right" }]
          ]
          period = 60
          stat   = "Sum"
        }
      },
      # ---- 行2中: Lambda Generator ----
      {
        type   = "metric"
        x      = 8
        y      = 8
        width  = 8
        height = 6
        properties = {
          title = "Lambda Generator"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", "${var.lambda_generator_function_name}"],
            ["AWS/Lambda", "Errors", "FunctionName", "${var.lambda_generator_function_name}", { "color" : "#d62728" }]
          ]
          period = 300
          stat   = "Sum"
        }
      },
      # ---- 行2右: Kinesis Firehose ----
      # DataFreshness はFirehoseバッファの最大滞留時間。60秒設定なので通常は60秒以下になる
      {
        type   = "metric"
        x      = 16
        y      = 8
        width  = 8
        height = 6
        properties = {
          title = "Kinesis Firehose - Records & Freshness"
          metrics = [
            ["AWS/Firehose", "IncomingRecords", "DeliveryStreamName", "${var.firehose_stream_name}"],
            ["AWS/Firehose", "DeliveryToS3.Records", "DeliveryStreamName", "${var.firehose_stream_name}"],
            ["AWS/Firehose", "DeliveryToS3.DataFreshness", "DeliveryStreamName", "${var.firehose_stream_name}", { "yAxis" : "right", "stat" : "Maximum" }]
          ]
          period = 60
          stat   = "Sum"
        }
      },
      # ---- 行3: タイトル ----
      {
        type   = "text"
        x      = 0
        y      = 14
        width  = 24
        height = 1
        properties = {
          markdown = "## DataBrew & Data Lake"
        }
      },
      # ---- 行3: DataBrew ログクエリウィジェット ----
      # DataBrewはCloudWatch Metricsを直接出さないためLogsインサイトクエリウィジェットで代替する
      {
        type   = "log"
        x      = 0
        y      = 15
        width  = 24
        height = 6
        properties = {
          title         = "DataBrew Job Execution History（直近10件）"
          query         = "fields @timestamp, @message\n| filter @logStream like /job/\n| sort @timestamp desc\n| limit 10"
          logGroupNames = ["${var.databrew_log_group_name}"]
          period        = 3600
          view          = "table"
        }
      }
    ]
  })
}

# ---- Alarm: Firehose配信エラー ----
# 15分間（3×5分）S3配信が0件なら異常とみなす
resource "aws_cloudwatch_metric_alarm" "firehose_delivery_error" {
  alarm_name  = "${var.name_prefix}-firehose-delivery-error"
  namespace   = "AWS/Firehose"
  metric_name = "DeliveryToS3.Success"
  dimensions = {
    DeliveryStreamName = var.firehose_stream_name
  }
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 3
  period              = 300
  statistic           = "Sum"
  alarm_description   = "Firehoseのデータ配信が停止しています（15分間S3配信が0件）"
  treat_missing_data  = "breaching"
}

# ---- Alarm: ALB 5xx急増 ----
# 1分間に10件以上の5xxエラーが2回連続したら異常
resource "aws_cloudwatch_metric_alarm" "alb_5xx_spike" {
  alarm_name  = "${var.name_prefix}-alb-5xx-spike"
  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 10
  evaluation_periods  = 2
  period              = 60
  statistic           = "Sum"
  alarm_description   = "ALBバックエンドエラーが急増しています（1分間10件以上が2回連続）"
  treat_missing_data  = "notBreaching"
}
