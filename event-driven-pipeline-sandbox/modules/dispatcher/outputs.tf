output "lambda_function_name" {
  description = "Dispatcher Lambda function name"
  value       = aws_lambda_function.dispatcher.function_name
}

output "lambda_function_arn" {
  description = "Dispatcher Lambda function ARN"
  value       = aws_lambda_function.dispatcher.arn
}
