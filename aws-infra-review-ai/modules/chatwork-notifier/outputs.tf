output "lambda_function_arn" {
  description = "chatwork-notifier Lambda 関数 ARN（Step Functions から呼び出す）"
  value       = aws_lambda_function.chatwork_notifier.arn
}

output "lambda_function_name" {
  description = "chatwork-notifier Lambda 関数名"
  value       = aws_lambda_function.chatwork_notifier.function_name
}
