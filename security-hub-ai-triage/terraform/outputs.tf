output "lambda_function_arn" {
  description = "triage-handler Lambda 関数の ARN"
  value       = module.lambda.function_arn
}

output "lambda_function_name" {
  description = "triage-handler Lambda 関数名"
  value       = module.lambda.function_name
}

output "dynamodb_table_name" {
  description = "重複排除 DynamoDB テーブル名"
  value       = module.dynamodb.table_name
}

output "s3_bucket_name" {
  description = "レポート保存 S3 バケット名"
  value       = module.s3.bucket_name
}

output "eventbridge_rule_arn" {
  description = "EventBridge ルールの ARN"
  value       = module.eventbridge.rule_arn
}
