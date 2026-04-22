output "dashboard_name" {
  description = "CloudWatch Dashboard name"
  value       = aws_cloudwatch_dashboard.streaming.dashboard_name
}

output "dashboard_url" {
  description = "CloudWatch Dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.streaming.dashboard_name}"
}

output "flink_alarm_arn" {
  description = "CloudWatch Alarm ARN for Flink no-records detection"
  value       = aws_cloudwatch_metric_alarm.flink_no_records.arn
}

output "flink_alarm_name" {
  description = "CloudWatch Alarm name for Flink no-records detection"
  value       = aws_cloudwatch_metric_alarm.flink_no_records.alarm_name
}
