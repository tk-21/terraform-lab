# =============================================================================
# S3モジュール アウトプット定義
# =============================================================================

output "bucket_name" {
  description = "レポート保存バケット名（report-formatter Lambda環境変数に設定）"
  value       = aws_s3_bucket.reports.bucket
}

output "bucket_arn" {
  description = "レポート保存バケットのARN（Lambda IAMポリシーのリソース指定に使用）"
  value       = aws_s3_bucket.reports.arn
}
