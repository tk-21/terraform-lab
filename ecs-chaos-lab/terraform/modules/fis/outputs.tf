output "scenario1_template_id" {
  description = "シナリオ1 (Task Kill) FIS 実験テンプレート ID"
  value       = aws_fis_experiment_template.task_kill.id
}

output "scenario2_template_id" {
  description = "シナリオ2 (Network Disruption) FIS 実験テンプレート ID"
  value       = aws_fis_experiment_template.network_disruption.id
}

output "scenario3_template_id" {
  description = "シナリオ3 (Desired Zero) FIS 実験テンプレート ID"
  value       = aws_fis_experiment_template.desired_zero.id
}

output "lambda_function_name" {
  description = "シナリオ3用 Lambda 関数名 (run_desired_zero.sh の復旧コマンドで使用)"
  value       = aws_lambda_function.desired_count_changer.function_name
}

output "fis_log_group_name" {
  description = "FIS 実験ログ出力先 CloudWatch Logs グループ名"
  value       = aws_cloudwatch_log_group.fis.name
}
