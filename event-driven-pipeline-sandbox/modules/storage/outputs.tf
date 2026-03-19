output "jobs_table_name" {
  description = "DynamoDB jobs table name"
  value       = aws_dynamodb_table.jobs.name
}

output "jobs_table_arn" {
  description = "DynamoDB jobs table ARN"
  value       = aws_dynamodb_table.jobs.arn
}

output "jobs_table_stream_arn" {
  description = "DynamoDB Streams ARN for the jobs table"
  value       = aws_dynamodb_table.jobs.stream_arn
}

output "metrics_table_name" {
  description = "DynamoDB metrics table name"
  value       = aws_dynamodb_table.metrics.name
}

output "metrics_table_arn" {
  description = "DynamoDB metrics table ARN"
  value       = aws_dynamodb_table.metrics.arn
}
