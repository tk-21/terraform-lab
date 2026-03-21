output "raw_bucket_id" {
  description = "S3 raw zone bucket name"
  value       = aws_s3_bucket.raw.id
}

output "raw_bucket_arn" {
  description = "S3 raw zone bucket ARN"
  value       = aws_s3_bucket.raw.arn
}

output "processed_bucket_id" {
  description = "S3 processed zone bucket name"
  value       = aws_s3_bucket.processed.id
}

output "processed_bucket_arn" {
  description = "S3 processed zone bucket ARN"
  value       = aws_s3_bucket.processed.arn
}

output "scripts_bucket_id" {
  description = "S3 scripts bucket name"
  value       = aws_s3_bucket.scripts.id
}

output "scripts_bucket_arn" {
  description = "S3 scripts bucket ARN"
  value       = aws_s3_bucket.scripts.arn
}

output "athena_results_bucket_id" {
  description = "S3 Athena results bucket name"
  value       = aws_s3_bucket.athena_results.id
}

output "athena_results_bucket_arn" {
  description = "S3 Athena results bucket ARN"
  value       = aws_s3_bucket.athena_results.arn
}
