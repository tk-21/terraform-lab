output "application_name" {
  description = "Flinkアプリケーション名"
  value       = aws_kinesisanalyticsv2_application.main.name
}

output "application_arn" {
  description = "FlinkアプリケーションARN"
  value       = aws_kinesisanalyticsv2_application.main.arn
}

output "log_group_name" {
  description = "FlinkアプリCloudWatch Logsグループ名"
  value       = aws_cloudwatch_log_group.flink.name
}
