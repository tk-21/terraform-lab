output "lambda_arn" {
  description = "Chatwork notifier Lambda function ARN"
  value       = aws_lambda_function.chatwork_notifier.arn
}

output "lambda_function_name" {
  description = "Chatwork notifier Lambda function name"
  value       = aws_lambda_function.chatwork_notifier.function_name
}

output "lambda_invoke_arn" {
  description = "Chatwork notifier Lambda invoke ARN (for Step Functions)"
  value       = aws_lambda_function.chatwork_notifier.invoke_arn
}

output "lambda_role_arn" {
  description = "Chatwork notifier Lambda IAM role ARN"
  value       = aws_iam_role.chatwork_notifier.arn
}
