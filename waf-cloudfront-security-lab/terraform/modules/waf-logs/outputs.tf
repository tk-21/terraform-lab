output "waf_logs_bucket_name" {
  description = "WAF ログ保存先 S3 バケット名 (Phase 4 のアラート通知補足情報として使用)"
  value       = aws_s3_bucket.waf_logs.bucket
}

output "waf_logs_bucket_arn" {
  description = "WAF ログ保存先 S3 バケット ARN"
  value       = aws_s3_bucket.waf_logs.arn
}

output "athena_workgroup_name" {
  description = "Athena ワークグループ名"
  value       = aws_athena_workgroup.main.name
}

output "athena_database_name" {
  description = "Athena データベース名"
  value       = aws_athena_database.waf.name
}

output "firehose_arn" {
  description = "Kinesis Firehose 配信ストリーム ARN"
  value       = aws_kinesis_firehose_delivery_stream.waf_logs.arn
}
