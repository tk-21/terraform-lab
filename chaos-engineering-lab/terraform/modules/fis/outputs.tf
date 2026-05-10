output "experiment_template_id" {
  description = "FIS 実験テンプレートの ID（run_experiment.sh で使用）"
  value       = aws_fis_experiment_template.cpu_stress.id
}

output "stop_condition_alarm_arn" {
  description = "FIS 停止条件 CloudWatch アラームの ARN"
  value       = aws_cloudwatch_metric_alarm.stop_condition.arn
}

output "log_group_name" {
  description = "FIS 実験ログの CloudWatch Logs ロググループ名"
  value       = aws_cloudwatch_log_group.fis.name
}
