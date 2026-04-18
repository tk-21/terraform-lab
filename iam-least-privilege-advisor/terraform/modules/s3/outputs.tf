output "bucket_id" {
  description = "S3 バケット ID（バケット名）"
  value       = aws_s3_bucket.results.id
}

output "bucket_arn" {
  description = "S3 バケットの ARN"
  value       = aws_s3_bucket.results.arn
}

output "bucket_name" {
  description = "S3 バケット名"
  value       = local.bucket_name
}
