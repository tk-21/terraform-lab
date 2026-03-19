output "lambda_function_name" {
  description = "Stream processor Lambda function name"
  value       = aws_lambda_function.stream_processor.function_name
}

output "lambda_function_arn" {
  description = "Stream processor Lambda function ARN"
  value       = aws_lambda_function.stream_processor.arn
}
