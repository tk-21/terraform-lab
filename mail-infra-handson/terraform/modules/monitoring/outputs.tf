output "alarm_topic_arn" {
  description = "CloudWatchアラーム通知用SNSトピックのARN"
  value       = aws_sns_topic.alarm.arn
}

output "bounce_rate_alarm_arn" {
  description = "バウンス率アラームのARN"
  value       = aws_cloudwatch_metric_alarm.ses_bounce_rate.arn
}

output "complaint_rate_alarm_arn" {
  description = "苦情率アラームのARN"
  value       = aws_cloudwatch_metric_alarm.ses_complaint_rate.arn
}

output "dashboard_name" {
  description = "CloudWatchダッシュボード名"
  value       = aws_cloudwatch_dashboard.mail.dashboard_name
}
