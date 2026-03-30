# terraform/modules/monitoring/outputs.tf

output "sns_topic_arn" {
  description = "アラーム通知用 SNS トピックの ARN。"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_url" {
  description = "CloudWatch ダッシュボードの URL。"
  value       = "https://console.aws.amazon.com/cloudwatch/home#dashboards:name=${aws_cloudwatch_dashboard.this.dashboard_name}"
}
