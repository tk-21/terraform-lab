output "monitor_alerts_topic_arn" {
  description = "Model Monitorアラート用SNSトピックのARN"
  value       = aws_sns_topic.monitor_alerts.arn
}

output "drift_handler_lambda_arn" {
  description = "ドリフト検知ハンドラーLambdaのARN"
  value       = aws_lambda_function.drift_handler.arn
}

output "data_quality_schedule_name" {
  description = "Data Quality MonitorスケジュールのARN"
  value       = aws_sagemaker_monitoring_schedule.data_quality.name
}

output "model_quality_schedule_name" {
  description = "Model Quality MonitorスケジュールのARN"
  value       = aws_sagemaker_monitoring_schedule.model_quality.name
}

output "endpoint_config_with_capture_name" {
  description = "Data Captureつきエンドポイント設定名（endpoint_model_name未設定の場合はnull）"
  value       = var.endpoint_model_name != "" ? aws_sagemaker_endpoint_configuration.with_data_capture[0].name : null
}
