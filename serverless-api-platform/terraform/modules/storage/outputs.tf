# terraform/modules/storage/outputs.tf

output "audit_bucket_name" {
  description = "監査ログ用 S3 バケット名。stream-processor の環境変数として渡す。"
  value       = aws_s3_bucket.audit_logs.bucket
}

output "audit_bucket_arn" {
  description = "監査ログ用 S3 バケットの ARN。IAM ポリシーで使用する。"
  value       = aws_s3_bucket.audit_logs.arn
}

output "audit_kms_key_arn" {
  description = "監査ログ用 KMS キーの ARN。stream-processor が PutObject する際に S3 が kms:GenerateDataKey を呼び出すため、Lambda 実行ロールへの権限付与に使用する。"
  value       = aws_kms_key.audit_logs.arn
}

output "lambda_deployment_bucket_name" {
  description = "Lambda デプロイパッケージ用 S3 バケット名。lambda-function モジュールの deployment_bucket_name に渡す。"
  value       = aws_s3_bucket.lambda_deployment.bucket
}
