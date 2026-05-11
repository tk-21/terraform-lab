output "fis_role_arn" {
  description = "FIS実行ロールのARN"
  value       = aws_iam_role.fis.arn
}

output "experiment_az_outage_id" {
  description = "AZ障害実験テンプレートID"
  value       = aws_fis_experiment_template.az_outage_cell_a.id
}

output "experiment_cpu_stress_id" {
  description = "CPUストレス実験テンプレートID"
  value       = aws_fis_experiment_template.pod_cpu_stress.id
}

output "experiment_network_latency_id" {
  description = "ネットワーク遅延実験テンプレートID"
  value       = aws_fis_experiment_template.network_latency.id
}

output "stop_condition_alarm_arn" {
  description = "Stop Condition用CloudWatchアラームARN（Phase 5の観測基盤で参照）"
  value       = aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn
}

output "fis_log_group_name" {
  description = "FIS実験ログのCloudWatch Logsグループ名"
  value       = aws_cloudwatch_log_group.fis.name
}
