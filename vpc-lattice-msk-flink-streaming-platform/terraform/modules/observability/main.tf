# CloudWatch Dashboard for the streaming platform
resource "aws_cloudwatch_dashboard" "streaming" {
  dashboard_name = "${var.name_prefix}-streaming-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: MSK metrics (2 columns)
      # MSK ServerlessはCluster単位のメトリクスのみ提供
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "MSK - BytesInPerSec"
          metrics = [["AWS/Kafka", "BytesInPerSec", "Cluster Name", var.msk_cluster_name]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "MSK - BytesOutPerSec"
          metrics = [["AWS/Kafka", "BytesOutPerSec", "Cluster Name", var.msk_cluster_name]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      # Row 2: Lambda Producer metrics (3 columns)
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Lambda - Invocations"
          metrics = [["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Lambda - Errors"
          metrics = [["AWS/Lambda", "Errors", "FunctionName", var.lambda_function_name]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Lambda - Duration P99"
          metrics = [["AWS/Lambda", "Duration", "FunctionName", var.lambda_function_name]]
          period  = 300
          stat    = "p99"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      # Row 3: Flink metrics (3 columns)
      # FlinkメトリクスはKinesis Analytics名前空間で確認
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "Flink - Records In/sec"
          metrics = [["AWS/KinesisAnalytics", "numRecordsInPerSecond", "Application", var.flink_app_name]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "Flink - Records Out/sec"
          metrics = [["AWS/KinesisAnalytics", "numRecordsOutPerSecond", "Application", var.flink_app_name]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          title   = "Flink - Checkpoint Duration"
          metrics = [["AWS/KinesisAnalytics", "lastCheckpointDuration", "Application", var.flink_app_name]]
          period  = 60
          stat    = "Maximum"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      # Row 4: VPC Lattice metrics (2 columns)
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "VPC Lattice - RequestCount"
          metrics = [["AWS/VpcLattice", "RequestCount", "ServiceName", var.vpc_lattice_service_name]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
          region  = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "VPC Lattice - 5XX Errors"
          metrics = [["AWS/VpcLattice", "HTTPCode_Target_5XX_Count", "ServiceName", var.vpc_lattice_service_name]]
          period  = 60
          stat    = "Sum"
          view    = "timeSeries"
          region  = var.aws_region
        }
      }
    ]
  })
}

# Flink停止検知アラーム: 5分間レコード数が0.1未満なら異常とみなす
resource "aws_cloudwatch_metric_alarm" "flink_no_records" {
  alarm_name        = "${var.name_prefix}-flink-no-records"
  alarm_description = "Flinkアプリがメッセージを処理していない可能性があります"
  namespace         = "AWS/KinesisAnalytics"
  metric_name       = "numRecordsInPerSecond"
  dimensions = {
    Application = var.flink_app_name
  }
  comparison_operator = "LessThanThreshold"
  threshold           = 0.1
  evaluation_periods  = 3
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "breaching"
  tags                = var.tags
}
