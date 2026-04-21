output "dashboard_name" {
  description = "CloudWatch Dashboard name"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "firehose_alarm_arn" {
  description = "CloudWatch Alarm ARN for Firehose delivery error"
  value       = aws_cloudwatch_metric_alarm.firehose_delivery_error.arn
}

output "alb_alarm_arn" {
  description = "CloudWatch Alarm ARN for ALB 5xx spike"
  value       = aws_cloudwatch_metric_alarm.alb_5xx_spike.arn
}
