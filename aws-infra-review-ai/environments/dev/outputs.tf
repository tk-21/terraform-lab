# =============================================================================
# 環境レベルの出力値
# CI/CD や他スタックから参照できるように主要リソースを出力
# =============================================================================

# --- storage ---
output "input_bucket_id" {
  description = "レビュー入力ファイル保存 S3 バケット名"
  value       = module.storage.input_bucket_id
}

output "reports_bucket_id" {
  description = "HTMLレポート保存 S3 バケット名"
  value       = module.storage.reports_bucket_id
}

output "review_table_name" {
  description = "議論ログ保存 DynamoDB テーブル名"
  value       = module.storage.review_table_name
}

# --- agents ---
output "security_reviewer_lambda_arn" {
  description = "security-reviewer Lambda ARN"
  value       = module.security_reviewer.lambda_function_arn
}

output "cost_reviewer_lambda_arn" {
  description = "cost-reviewer Lambda ARN"
  value       = module.cost_reviewer.lambda_function_arn
}

output "reliability_reviewer_lambda_arn" {
  description = "reliability-reviewer Lambda ARN"
  value       = module.reliability_reviewer.lambda_function_arn
}

output "operations_reviewer_lambda_arn" {
  description = "operations-reviewer Lambda ARN"
  value       = module.operations_reviewer.lambda_function_arn
}

# --- api ---
output "api_endpoint" {
  description = "API Gateway エンドポイント URL"
  value       = module.api.api_endpoint
}

# --- supervisor ---
output "supervisor_lambda_arn" {
  description = "supervisor Lambda ARN"
  value       = module.supervisor.lambda_function_arn
}

# --- workflow ---
output "state_machine_arn" {
  description = "Step Functions レビューワークフロー ARN"
  value       = module.workflow.state_machine_arn
}

output "state_machine_name" {
  description = "Step Functions レビューワークフロー名"
  value       = module.workflow.state_machine_name
}

output "workflow_starter_lambda_arn" {
  description = "workflow-starter Lambda ARN（S3 PUT でトリガー）"
  value       = module.workflow.workflow_starter_lambda_arn
}

# --- report-generator ---
output "report_generator_lambda_arn" {
  description = "report-generator Lambda ARN"
  value       = module.report_generator.lambda_function_arn
}

# --- chatwork-notifier ---
output "chatwork_notifier_lambda_arn" {
  description = "chatwork-notifier Lambda ARN"
  value       = module.chatwork_notifier.lambda_function_arn
}

output "chatwork_token_ssm_path" {
  description = "Chatwork API トークンの SSM Parameter Store パス"
  value       = aws_ssm_parameter.chatwork_api_token.name
}

# --- observability ---
output "alarm_sns_topic_arn" {
  description = "CloudWatch アラーム通知用 SNS トピック ARN"
  value       = module.observability.alarm_sns_topic_arn
}
