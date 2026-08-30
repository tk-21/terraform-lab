resource "aws_sns_topic" "alerts" {
  # HIGH/CRITICAL Finding の通知先。AWS 管理キーで保管時暗号化する。
  name              = "${var.project_name}-alerts-${var.environment}"
  display_name      = "Security Hub Alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
