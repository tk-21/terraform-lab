output "report_bucket_name" {
  description = "S3 bucket name for FinOps reports"
  value       = aws_s3_bucket.reports.id
}

output "report_bucket_arn" {
  description = "S3 bucket ARN for FinOps reports"
  value       = aws_s3_bucket.reports.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for report history"
  value       = aws_dynamodb_table.report_history.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN for report history"
  value       = aws_dynamodb_table.report_history.arn
}
