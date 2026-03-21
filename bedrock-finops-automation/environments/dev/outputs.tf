output "report_bucket_name" {
  description = "S3 bucket name for FinOps reports"
  value       = module.storage.report_bucket_name
}

output "report_bucket_arn" {
  description = "S3 bucket ARN for FinOps reports"
  value       = module.storage.report_bucket_arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for report history"
  value       = module.storage.dynamodb_table_name
}

output "collector_lambda_arn" {
  description = "Collector Lambda function ARN"
  value       = module.collector.lambda_arn
}

output "collector_lambda_function_name" {
  description = "Collector Lambda function name"
  value       = module.collector.lambda_function_name
}

output "anomaly_detector_lambda_arn" {
  description = "Anomaly detector Lambda function ARN"
  value       = module.anomaly_detector.lambda_arn
}

output "anomaly_detector_lambda_function_name" {
  description = "Anomaly detector Lambda function name"
  value       = module.anomaly_detector.lambda_function_name
}

output "ai_reporter_lambda_arn" {
  description = "AI reporter Lambda function ARN"
  value       = module.ai_reporter.lambda_arn
}

output "ai_reporter_lambda_function_name" {
  description = "AI reporter Lambda function name"
  value       = module.ai_reporter.lambda_function_name
}

output "html_formatter_lambda_arn" {
  description = "HTML formatter Lambda function ARN"
  value       = module.html_formatter.lambda_arn
}

output "html_formatter_lambda_function_name" {
  description = "HTML formatter Lambda function name"
  value       = module.html_formatter.lambda_function_name
}

output "chatwork_notifier_lambda_arn" {
  description = "Chatwork notifier Lambda function ARN"
  value       = module.chatwork_notifier.lambda_arn
}

output "chatwork_notifier_lambda_function_name" {
  description = "Chatwork notifier Lambda function name"
  value       = module.chatwork_notifier.lambda_function_name
}

output "state_machine_arn" {
  description = "Step Functions state machine ARN"
  value       = module.workflow.state_machine_arn
}

output "state_machine_name" {
  description = "Step Functions state machine name"
  value       = module.workflow.state_machine_name
}
