output "lambda_arn" {
  description = "Collector Lambda function ARN"
  value       = aws_lambda_function.collector.arn
}

output "lambda_function_name" {
  description = "Collector Lambda function name"
  value       = aws_lambda_function.collector.function_name
}

output "lambda_invoke_arn" {
  description = "Collector Lambda invoke ARN (for Step Functions)"
  value       = aws_lambda_function.collector.invoke_arn
}

output "lambda_role_arn" {
  description = "Collector Lambda IAM role ARN"
  value       = aws_iam_role.collector.arn
}
