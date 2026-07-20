output "dashboard_url" {
  description = "CloudWatch ダッシュボード URL"
  value       = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home#dashboards:name=${var.project}-pipeline"
}

output "sfn_failures_alarm_arn" {
  description = "Step Functions 失敗アラーム ARN"
  value       = aws_cloudwatch_metric_alarm.sfn_failures.arn
}

output "inventory_errors_alarm_arn" {
  description = "在庫確認エラーアラーム ARN"
  value       = aws_cloudwatch_metric_alarm.inventory_errors.arn
}

output "dlq_messages_alarm_arn" {
  description = "DLQ メッセージアラーム ARN"
  value       = aws_cloudwatch_metric_alarm.dlq_messages.arn
}
