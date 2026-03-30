output "table_name" {
  description = "DynamoDB テーブル名"
  value       = aws_dynamodb_table.dedup.name
}

output "table_arn" {
  description = "DynamoDB テーブルの ARN"
  value       = aws_dynamodb_table.dedup.arn
}
