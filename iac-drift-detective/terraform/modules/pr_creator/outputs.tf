output "function_arn" {
  description = "pr-creator LambdaのARN"
  value       = aws_lambda_function.pr_creator.arn
}

output "function_name" {
  description = "pr-creator Lambda関数名"
  value       = aws_lambda_function.pr_creator.function_name
}

output "invoke_arn" {
  description = "pr-creator LambdaのInvoke ARN（Step Functions用）"
  value       = aws_lambda_function.pr_creator.invoke_arn
}
