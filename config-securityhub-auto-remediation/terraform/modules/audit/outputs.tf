output "audit_bucket_name" {
  description = "S3監査ログバケット名"
  value       = aws_s3_bucket.audit.bucket
}

output "audit_bucket_arn" {
  description = "S3監査ログバケットARN"
  value       = aws_s3_bucket.audit.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB修復ログテーブル名"
  value       = aws_dynamodb_table.remediation_log.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB修復ログテーブルARN"
  value       = aws_dynamodb_table.remediation_log.arn
}

output "dlq_arn" {
  description = "SQS DLQ ARN"
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "SQS DLQ URL"
  value       = aws_sqs_queue.dlq.url
}

output "dlq_queue_name" {
  description = "SQS DLQ キュー名 (CloudWatch メトリクスのdimension用)"
  value       = aws_sqs_queue.dlq.name
}
