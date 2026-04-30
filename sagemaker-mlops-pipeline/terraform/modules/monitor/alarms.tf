# =====================
# SNS Topic（CloudWatch Alarm → Lambda）
# =====================
resource "aws_sns_topic" "monitor_alerts" {
  name = "${local.prefix}-monitor-alerts"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "drift_handler" {
  topic_arn = aws_sns_topic.monitor_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.drift_handler.arn
}

# =====================
# CloudWatch Alarms
# =====================

# Data Qualityドリフト検知アラーム
resource "aws_cloudwatch_metric_alarm" "data_drift" {
  alarm_name          = "${local.prefix}-data-drift-alarm"
  alarm_description   = "入力データのドリフトがベースラインから逸脱"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "feature_baseline_drift_max"
  namespace           = "aws/sagemaker/Endpoints/data-metrics"
  period              = 3600
  statistic           = "Maximum"
  threshold           = 0.5 # 日本語コメント: PSI(人口安定性指数) > 0.5で有意なドリフト

  dimensions = {
    MonitoringSchedule = aws_sagemaker_monitoring_schedule.data_quality.name
    Endpoint           = var.endpoint_name
  }

  alarm_actions = [aws_sns_topic.monitor_alerts.arn]
  ok_actions    = [aws_sns_topic.monitor_alerts.arn]
  tags          = local.common_tags
}

# Model Qualityアラーム
resource "aws_cloudwatch_metric_alarm" "model_quality" {
  alarm_name          = "${local.prefix}-model-quality-alarm"
  alarm_description   = "モデル予測精度がベースラインから劣化"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "binary_classification_accuracy"
  namespace           = "aws/sagemaker/Endpoints/model-metrics"
  period              = 3600
  statistic           = "Average"
  threshold           = 0.75 # 日本語コメント: 精度75%を下回ったら再学習トリガー

  dimensions = {
    MonitoringSchedule = aws_sagemaker_monitoring_schedule.model_quality.name
    Endpoint           = var.endpoint_name
  }

  alarm_actions = [aws_sns_topic.monitor_alerts.arn]
  tags          = local.common_tags
}
