output "lambda_arn" {
  description = "AI reporter Lambda function ARN"
  value       = aws_lambda_function.ai_reporter.arn
}

output "lambda_function_name" {
  description = "AI reporter Lambda function name"
  value       = aws_lambda_function.ai_reporter.function_name
}

output "lambda_invoke_arn" {
  description = "AI reporter Lambda invoke ARN (for Step Functions)"
  value       = aws_lambda_function.ai_reporter.invoke_arn
}

output "lambda_role_arn" {
  description = "AI reporter Lambda IAM role ARN"
  value       = aws_iam_role.ai_reporter.arn
}
