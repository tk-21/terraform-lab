output "alarm_sns_topic_arn" {
  description = "CloudWatch アラーム通知用 SNS トピック ARN"
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "作成した CloudWatch アラーム名の一覧"
  value = [
    aws_cloudwatch_metric_alarm.sf_executions_failed.alarm_name,
    aws_cloudwatch_metric_alarm.sf_executions_timed_out.alarm_name,
    aws_cloudwatch_metric_alarm.workflow_starter_errors.alarm_name,
    aws_cloudwatch_metric_alarm.supervisor_errors.alarm_name,
  ]
}
