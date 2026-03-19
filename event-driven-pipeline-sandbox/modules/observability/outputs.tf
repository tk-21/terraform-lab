output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.pipeline.dashboard_name
}

output "xray_group_name" {
  description = "X-Ray group name"
  value       = aws_xray_group.pipeline.group_name
}

output "dlq_alarm_arn" {
  description = "CloudWatch alarm ARN for DLQ message accumulation"
  value       = aws_cloudwatch_metric_alarm.dlq_messages.arn
}
