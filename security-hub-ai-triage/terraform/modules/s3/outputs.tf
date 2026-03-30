output "bucket_name" {
  description = "S3 バケット名"
  value       = aws_s3_bucket.reports.bucket
}

output "bucket_arn" {
  description = "S3 バケットの ARN"
  value       = aws_s3_bucket.reports.arn
}
