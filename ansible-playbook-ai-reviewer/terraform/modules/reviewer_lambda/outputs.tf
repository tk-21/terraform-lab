output "lambda_arn" {
  description = "Lambda関数のARN"
  value       = aws_lambda_function.reviewer.arn
}

output "lambda_invoke_arn" {
  description = "Lambda関数の呼び出しARN（API Gateway統合で使用）"
  value       = aws_lambda_function.reviewer.invoke_arn
}

output "lambda_function_name" {
  description = "Lambda関数名"
  value       = aws_lambda_function.reviewer.function_name
}
