output "state_machine_arn" {
  description = "Step Functions state machine ARN"
  value       = aws_sfn_state_machine.finops_workflow.arn
}

output "state_machine_name" {
  description = "Step Functions state machine name"
  value       = aws_sfn_state_machine.finops_workflow.name
}

output "state_machine_role_arn" {
  description = "IAM role ARN used by the state machine"
  value       = aws_iam_role.state_machine.arn
}
