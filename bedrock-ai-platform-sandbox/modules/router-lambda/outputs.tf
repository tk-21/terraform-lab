output "lambda_function_name" {
  description = "Router Lambda function name"
  value       = aws_lambda_function.router.function_name
}

output "lambda_function_arn" {
  description = "Router Lambda function ARN"
  value       = aws_lambda_function.router.arn
}

output "lambda_invoke_arn" {
  description = "Router Lambda invoke ARN (used by API Gateway)"
  value       = aws_lambda_function.router.invoke_arn
}

output "lambda_role_arn" {
  description = "IAM role ARN for the Router Lambda"
  value       = aws_iam_role.router_lambda.arn
}

output "lambda_role_name" {
  description = "IAM role name for the Router Lambda"
  value       = aws_iam_role.router_lambda.name
}

output "lambda_security_group_id" {
  description = "Security group ID for the Router Lambda"
  value       = aws_security_group.router_lambda.id
}

output "lambda_log_group" {
  description = "CloudWatch Log Group for the Router Lambda"
  value       = aws_cloudwatch_log_group.router_lambda.name
}
