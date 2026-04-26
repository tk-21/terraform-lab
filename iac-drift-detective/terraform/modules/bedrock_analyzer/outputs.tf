output "function_arn" {
  description = "bedrock-analyzer LambdaのARN"
  value       = aws_lambda_function.bedrock_analyzer.arn
}

output "function_name" {
  description = "bedrock-analyzer Lambda関数名"
  value       = aws_lambda_function.bedrock_analyzer.function_name
}

output "invoke_arn" {
  description = "bedrock-analyzer LambdaのInvoke ARN（Step Functions用）"
  value       = aws_lambda_function.bedrock_analyzer.invoke_arn
}
