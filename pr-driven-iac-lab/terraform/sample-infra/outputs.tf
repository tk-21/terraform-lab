output "s3_bucket_name" {
  description = "sample-infra S3バケット名"
  value       = aws_s3_bucket.main.bucket
}

output "s3_bucket_arn" {
  description = "sample-infra S3バケットARN"
  value       = aws_s3_bucket.main.arn
}

output "iam_role_arn" {
  description = "S3読み取り専用IAMロールARN"
  value       = aws_iam_role.s3_reader.arn
}
