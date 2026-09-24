output "lambda_arn" {
  description = "SNS Notifier Lambda function ARN"
  value       = aws_lambda_function.sns_notifier.arn
}

output "lambda_name" {
  description = "SNS Notifier Lambda function name"
  value       = aws_lambda_function.sns_notifier.function_name
}

output "sns_topic_arn" {
  description = "SNS Topic ARN for cost report notifications"
  value       = aws_sns_topic.cost_report.arn
}
