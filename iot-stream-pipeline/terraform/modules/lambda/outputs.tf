output "processor_function_name" {
  description = "processor Lambda関数名"
  value       = aws_lambda_function.processor.function_name
}

output "reader_function_name" {
  description = "reader Lambda関数名"
  value       = aws_lambda_function.reader.function_name
}

output "reader_function_arn" {
  description = "reader LambdaのARN"
  value       = aws_lambda_function.reader.arn
}

output "reader_invoke_arn" {
  description = "reader LambdaのInvoke ARN (API Gateway統合設定で使用)"
  value       = aws_lambda_function.reader.invoke_arn
}
