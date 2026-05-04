output "receipt_rule_set_name" {
  description = "SES Receipt Rule Set名"
  value       = aws_ses_receipt_rule_set.main.rule_set_name
}

output "s3_inbound_bucket_name" {
  description = "受信メール保存用S3バケット名"
  value       = aws_s3_bucket.inbound_mail.id
}

output "s3_inbound_bucket_arn" {
  description = "受信メール保存用S3バケットのARN"
  value       = aws_s3_bucket.inbound_mail.arn
}

output "spam_handler_function_name" {
  description = "spam_handler Lambda関数名。monitoringモジュールのダッシュボードで参照する"
  value       = aws_lambda_function.spam_handler.function_name
}

output "spam_handler_function_arn" {
  description = "spam_handler Lambda関数のARN"
  value       = aws_lambda_function.spam_handler.arn
}

output "spam_log_table_name" {
  description = "スパムログDynamoDBテーブル名"
  value       = aws_dynamodb_table.spam_log.name
}

output "spam_log_table_arn" {
  description = "スパムログDynamoDBテーブルのARN"
  value       = aws_dynamodb_table.spam_log.arn
}
