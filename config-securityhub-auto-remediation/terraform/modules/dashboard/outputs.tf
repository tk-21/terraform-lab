output "dashboard_arn" {
  description = "CloudWatch Dashboard ARN"
  value       = aws_cloudwatch_dashboard.csar_main.dashboard_arn
}

output "sns_topic_arn" {
  description = "アラート通知用SNS Topic ARN"
  value       = aws_sns_topic.csar_alerts.arn
}

output "dlq_alarm_name" {
  description = "DLQ深度アラーム名"
  value       = aws_cloudwatch_metric_alarm.dlq_depth.alarm_name
}
