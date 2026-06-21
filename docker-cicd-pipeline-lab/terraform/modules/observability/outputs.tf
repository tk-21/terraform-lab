output "dashboard_url" {
  description = "CloudWatch ダッシュボードの URL"
  value       = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=${var.name_prefix}-overview"
}

output "ecs_alarm_arn" {
  description = "ECS タスク数アラームの ARN"
  value       = aws_cloudwatch_metric_alarm.ecs_running_tasks.arn
}

output "alb_5xx_alarm_arn" {
  description = "ALB 5xx エラーアラームの ARN"
  value       = aws_cloudwatch_metric_alarm.alb_5xx.arn
}

output "pipeline_failure_log_group" {
  description = "パイプライン失敗イベントの CloudWatch Logs グループ名"
  value       = aws_cloudwatch_log_group.events.name
}
