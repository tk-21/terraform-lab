output "dlq_handler_function_name" {
  description = "DLQ handler Lambda function name"
  value       = aws_lambda_function.dlq_handler.function_name
}

output "dlq_handler_function_arn" {
  description = "DLQ handler Lambda function ARN"
  value       = aws_lambda_function.dlq_handler.arn
}

output "sfn_failure_rule_arn" {
  description = "EventBridge rule ARN for SFN failure events"
  value       = aws_cloudwatch_event_rule.sfn_failure.arn
}

output "cleanup_rule_arn" {
  description = "EventBridge rule ARN for scheduled cleanup"
  value       = aws_cloudwatch_event_rule.cleanup_schedule.arn
}
