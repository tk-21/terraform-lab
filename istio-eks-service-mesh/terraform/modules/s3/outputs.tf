output "bucket_name" {
  description = "S3レポートバケット名"
  value       = aws_s3_bucket.reports.bucket
}

output "bucket_arn" {
  description = "S3レポートバケットARN"
  value       = aws_s3_bucket.reports.arn
}
