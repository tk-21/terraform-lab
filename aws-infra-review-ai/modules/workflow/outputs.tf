output "state_machine_arn" {
  description = "Step Functions ステートマシン ARN"
  value       = aws_sfn_state_machine.review_workflow.arn
}

output "state_machine_name" {
  description = "Step Functions ステートマシン名"
  value       = aws_sfn_state_machine.review_workflow.name
}

output "workflow_starter_lambda_arn" {
  description = "workflow-starter Lambda ARN（S3 イベントでトリガー）"
  value       = aws_lambda_function.workflow_starter.arn
}

output "workflow_starter_function_name" {
  description = "workflow-starter Lambda 関数名（CloudWatch アラーム設定用）"
  value       = aws_lambda_function.workflow_starter.function_name
}
