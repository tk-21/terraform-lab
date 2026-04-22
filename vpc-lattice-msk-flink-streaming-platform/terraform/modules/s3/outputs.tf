output "output_bucket_id" {
  description = "ID of the Flink event output S3 bucket"
  value       = aws_s3_bucket.output.id
}

output "output_bucket_arn" {
  description = "ARN of the Flink event output S3 bucket"
  value       = aws_s3_bucket.output.arn
}

output "flink_app_bucket_id" {
  description = "ID of the Flink application (JAR) storage S3 bucket"
  value       = aws_s3_bucket.flink_app.id
}

output "flink_app_bucket_arn" {
  description = "ARN of the Flink application (JAR) storage S3 bucket"
  value       = aws_s3_bucket.flink_app.arn
}

output "output_bucket_name" {
  description = "Name of the Flink event output S3 bucket"
  value       = aws_s3_bucket.output.bucket
}

output "flink_app_bucket_name" {
  description = "Name of the Flink application (JAR) storage S3 bucket"
  value       = aws_s3_bucket.flink_app.bucket
}
