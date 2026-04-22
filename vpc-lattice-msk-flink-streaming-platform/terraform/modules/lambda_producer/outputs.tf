output "lambda_function_name" {
  description = "Lambda関数名"
  value       = aws_lambda_function.producer.function_name
}

output "lambda_function_arn" {
  description = "Lambda関数ARN"
  value       = aws_lambda_function.producer.arn
}

output "scheduler_name" {
  description = "EventBridge Schedulerスケジュール名"
  value       = aws_scheduler_schedule.producer.name
}
