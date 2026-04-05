output "input_bucket_id" {
  description = "レビュー入力ファイル S3 バケット名"
  value       = aws_s3_bucket.input.id
}

output "input_bucket_arn" {
  description = "レビュー入力ファイル S3 バケット ARN"
  value       = aws_s3_bucket.input.arn
}

output "reports_bucket_id" {
  description = "HTML レポート S3 バケット名"
  value       = aws_s3_bucket.reports.id
}

output "reports_bucket_arn" {
  description = "HTML レポート S3 バケット ARN"
  value       = aws_s3_bucket.reports.arn
}

output "review_table_name" {
  description = "議論ログ DynamoDB テーブル名"
  value       = aws_dynamodb_table.review_sessions.name
}

output "review_table_arn" {
  description = "議論ログ DynamoDB テーブル ARN"
  value       = aws_dynamodb_table.review_sessions.arn
}
