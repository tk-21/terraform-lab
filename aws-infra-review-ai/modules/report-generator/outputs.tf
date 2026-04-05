output "lambda_function_arn" {
  description = "report-generator Lambda 関数 ARN（Step Functions から呼び出す）"
  value       = aws_lambda_function.report_generator.arn
}

output "lambda_function_name" {
  description = "report-generator Lambda 関数名"
  value       = aws_lambda_function.report_generator.function_name
}
