output "function_arn" {
  description = "drift-detector LambdaのARN"
  value       = aws_lambda_function.drift_detector.arn
}

output "function_name" {
  description = "drift-detector Lambda関数名"
  value       = aws_lambda_function.drift_detector.function_name
}

output "invoke_arn" {
  description = "drift-detector LambdaのInvoke ARN（Step Functions用）"
  value       = aws_lambda_function.drift_detector.invoke_arn
}
