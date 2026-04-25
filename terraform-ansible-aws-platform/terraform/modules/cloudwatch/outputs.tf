output "ssm_parameter_name" {
  description = "CloudWatch Agent設定のSSMパラメータ名"
  value       = aws_ssm_parameter.cw_agent_config.name
}

output "sns_topic_arn" {
  description = "アラート通知SNSトピックARN"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "CloudWatchダッシュボード名"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
