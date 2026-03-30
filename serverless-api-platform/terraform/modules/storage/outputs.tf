# terraform/modules/storage/outputs.tf

output "audit_bucket_name" {
  description = "監査ログ用 S3 バケット名。stream-processor の環境変数として渡す。"
  value       = aws_s3_bucket.audit_logs.bucket
}

output "audit_bucket_arn" {
  description = "監査ログ用 S3 バケットの ARN。IAM ポリシーで使用する。"
  value       = aws_s3_bucket.audit_logs.arn
}
