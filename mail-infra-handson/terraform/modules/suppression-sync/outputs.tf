output "function_name" {
  description = "suppression_manager Lambda関数名"
  value       = aws_lambda_function.suppression_mgr.function_name
}

output "function_arn" {
  description = "suppression_manager Lambda関数のARN"
  value       = aws_lambda_function.suppression_mgr.arn
}

output "schedule_arn" {
  description = "EventBridgeスケジュールのARN"
  value       = aws_scheduler_schedule.daily.arn
}
