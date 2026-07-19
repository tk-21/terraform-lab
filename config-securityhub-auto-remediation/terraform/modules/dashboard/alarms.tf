# ===== SNS Topic: アラーム通知ハブ =====
# Chatworkに直接通知せずSNSを中継する理由:
# SNSサブスクリプションの追加のみで通知先を増やせる (Slack/PagerDuty等への拡張が容易)
resource "aws_sns_topic" "csar_alerts" {
  name = "csar-alerts"

  # AWSマネージドキーで暗号化
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name = "csar-alerts"
  }
}

# ===== DLQ深度アラーム =====
# 修復DLQにメッセージが蓄積 = Lambdaが3回リトライ後も失敗したことを意味する
# 1件でも発生したら即座に通知する (閾値を下げる理由: 修復漏れは即セキュリティリスク)
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "csar-dlq-messages-visible"
  alarm_description   = "修復DLQにメッセージが蓄積されています。Lambda修復関数の障害を確認してください。"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.dlq_queue_name
  }

  alarm_actions = [aws_sns_topic.csar_alerts.arn]
  ok_actions    = [aws_sns_topic.csar_alerts.arn]
}

# ===== Lambda エラー数アラーム =====
# 5分間に3回以上エラー = 一時的な失敗ではなく継続的な障害の可能性が高い
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = toset([
    "csar-s3-remediation",
    "csar-iam-remediation",
    "csar-sg-remediation",
    "csar-rds-remediation",
  ])

  alarm_name          = "csar-lambda-error-${each.key}"
  alarm_description   = "${each.key} のエラーが閾値を超えました (5分間で3回以上)"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.key
  }

  alarm_actions = [aws_sns_topic.csar_alerts.arn]
}
