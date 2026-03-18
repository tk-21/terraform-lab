output "tenant_table_name" {
  description = "DynamoDB table name for tenant configuration"
  value       = aws_dynamodb_table.tenants.name
}

output "tenant_table_arn" {
  description = "DynamoDB table ARN for tenant configuration"
  value       = aws_dynamodb_table.tenants.arn
}

output "usage_table_name" {
  description = "DynamoDB table name for token usage tracking"
  value       = aws_dynamodb_table.usage.name
}

output "usage_table_arn" {
  description = "DynamoDB table ARN for token usage tracking"
  value       = aws_dynamodb_table.usage.arn
}
