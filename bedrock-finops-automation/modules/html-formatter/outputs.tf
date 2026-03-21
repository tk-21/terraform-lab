output "lambda_arn" {
  description = "HTML formatter Lambda function ARN"
  value       = aws_lambda_function.html_formatter.arn
}

output "lambda_function_name" {
  description = "HTML formatter Lambda function name"
  value       = aws_lambda_function.html_formatter.function_name
}

output "lambda_invoke_arn" {
  description = "HTML formatter Lambda invoke ARN (for Step Functions)"
  value       = aws_lambda_function.html_formatter.invoke_arn
}

output "lambda_role_arn" {
  description = "HTML formatter Lambda IAM role ARN"
  value       = aws_iam_role.html_formatter.arn
}
