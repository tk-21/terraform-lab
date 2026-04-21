output "function_arn" {
  description = "ARN of the Lambda Generator function"
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "Name of the Lambda Generator function"
  value       = aws_lambda_function.this.function_name
}
