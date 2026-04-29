output "state_machine_arn" {
  description = "Step Functions ステートマシンARN"
  value       = aws_sfn_state_machine.ops_orchestrator.arn
}

output "state_machine_name" {
  description = "Step Functions ステートマシン名"
  value       = aws_sfn_state_machine.ops_orchestrator.name
}

output "sfn_role_arn" {
  description = "Step Functions実行ロールARN"
  value       = aws_iam_role.sfn_orchestrator.arn
}
