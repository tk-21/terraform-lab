output "lambda_function_arn" {
  description = "cost-reviewer Lambda 関数 ARN（Step Functions から呼び出す）"
  value       = aws_lambda_function.cost_reviewer.arn
}

output "lambda_function_name" {
  description = "cost-reviewer Lambda 関数名"
  value       = aws_lambda_function.cost_reviewer.function_name
}

output "lambda_invoke_arn" {
  description = "cost-reviewer Lambda 呼び出し ARN（API Gateway 統合に使用）"
  value       = aws_lambda_function.cost_reviewer.invoke_arn
}
