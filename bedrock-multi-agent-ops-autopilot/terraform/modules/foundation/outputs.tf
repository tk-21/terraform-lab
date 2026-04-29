output "s3_reports_bucket_name" {
  description = "HTMLレポート保存用S3バケット名"
  value       = aws_s3_bucket.reports.bucket
}

output "dynamodb_execution_history_table_name" {
  description = "Agent実行履歴DynamoDBテーブル名"
  value       = aws_dynamodb_table.execution_history.name
}

output "dynamodb_approval_requests_table_name" {
  description = "Human-in-the-loop承認リクエストDynamoDBテーブル名"
  value       = aws_dynamodb_table.approval_requests.name
}

output "lambda_base_role_arn" {
  description = "Lambda共通実行ロールARN"
  value       = aws_iam_role.lambda_base.arn
}

output "supervisor_agent_role_arn" {
  description = "Supervisor Bedrock AgentロールARN"
  value       = aws_iam_role.supervisor_agent.arn
}

output "dynamodb_execution_history_table_arn" {
  description = "Agent実行履歴DynamoDBテーブルARN"
  value       = aws_dynamodb_table.execution_history.arn
}

output "cloudwatch_log_group_stepfunctions_arn" {
  description = "Step Functions実行ログ用CloudWatch LogsグループARN"
  value       = aws_cloudwatch_log_group.stepfunctions_orchestrator.arn
}
