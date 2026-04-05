output "lambda_function_arn" {
  description = "supervisor Lambda 関数 ARN（Step Functions から呼び出す）"
  value       = aws_lambda_function.supervisor.arn
}

output "lambda_function_name" {
  description = "supervisor Lambda 関数名"
  value       = aws_lambda_function.supervisor.function_name
}

output "lambda_invoke_arn" {
  description = "supervisor Lambda 呼び出し ARN"
  value       = aws_lambda_function.supervisor.invoke_arn
}
