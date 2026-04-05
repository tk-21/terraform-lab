output "lambda_function_arn" {
  description = "security-reviewer Lambda 関数 ARN（Step Functions から呼び出す）"
  value       = aws_lambda_function.security_reviewer.arn
}

output "lambda_function_name" {
  description = "security-reviewer Lambda 関数名"
  value       = aws_lambda_function.security_reviewer.function_name
}

output "lambda_invoke_arn" {
  description = "security-reviewer Lambda 呼び出し ARN（API Gateway 統合に使用）"
  value       = aws_lambda_function.security_reviewer.invoke_arn
}
