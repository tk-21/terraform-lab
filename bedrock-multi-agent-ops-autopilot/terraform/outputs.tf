output "s3_reports_bucket_name" {
  description = "HTMLレポート保存用S3バケット名"
  value       = module.foundation.s3_reports_bucket_name
}

output "dynamodb_execution_history_table_name" {
  description = "Agent実行履歴DynamoDBテーブル名"
  value       = module.foundation.dynamodb_execution_history_table_name
}

output "dynamodb_approval_requests_table_name" {
  description = "Human-in-the-loop承認リクエストDynamoDBテーブル名"
  value       = module.foundation.dynamodb_approval_requests_table_name
}

output "lambda_base_role_arn" {
  description = "Lambda共通実行ロールARN"
  value       = module.foundation.lambda_base_role_arn
}

output "supervisor_agent_role_arn" {
  description = "Supervisor Bedrock AgentロールARN"
  value       = module.foundation.supervisor_agent_role_arn
}

output "supervisor_agent_id" {
  description = "Supervisor Bedrock Agent ID"
  value       = module.agents.supervisor_agent_id
}

output "supervisor_agent_alias_id" {
  description = "Supervisor Bedrock Agent エイリアスID"
  value       = module.agents.supervisor_agent_alias_id
}

output "state_machine_arn" {
  description = "Step Functions ステートマシンARN"
  value       = module.stepfunctions.state_machine_arn
}

output "state_machine_name" {
  description = "Step Functions ステートマシン名"
  value       = module.stepfunctions.state_machine_name
}
