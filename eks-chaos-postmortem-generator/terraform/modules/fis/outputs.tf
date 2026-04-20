# =============================================================================
# FISモジュール アウトプット定義
# =============================================================================

output "pod_kill_experiment_template_id" {
  description = "Pod Kill実験テンプレートID（手動実験トリガー時に使用）"
  value       = aws_fis_experiment_template.pod_kill.id
}

output "node_termination_experiment_template_id" {
  description = "Node Termination実験テンプレートID"
  value       = aws_fis_experiment_template.node_termination.id
}

output "network_latency_experiment_template_id" {
  description = "Network Latency実験テンプレートID"
  value       = aws_fis_experiment_template.network_latency.id
}

output "cpu_stress_experiment_template_id" {
  description = "CPU Stress実験テンプレートID"
  value       = aws_fis_experiment_template.cpu_stress.id
}

output "fis_execution_role_arn" {
  description = "FIS実験実行IAMロールのARN（EventBridgeやFIS設定で参照）"
  value       = aws_iam_role.fis_execution.arn
}

output "stop_condition_alarm_arn" {
  description = "StopCondition用CloudWatchアラームのARN"
  value       = aws_cloudwatch_metric_alarm.fis_stop_condition.arn
}

output "chaos_dashboard_name" {
  description = "カオスエンジニアリング可視化ダッシュボード名"
  value       = aws_cloudwatch_dashboard.chaos.dashboard_name
}
