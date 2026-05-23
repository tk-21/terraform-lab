output "invoke_bedrock_arn" {
  description = "Bedrock推論Lambda関数のARN"
  value       = aws_lambda_function.invoke_bedrock.arn
}

output "notify_chatwork_arn" {
  description = "Chatwork通知Lambda関数のARN"
  value       = aws_lambda_function.notify_chatwork.arn
}

output "lambda_security_group_id" {
  description = "Lambda共用セキュリティグループID（Step Functionsモジュールで参照）"
  value       = aws_security_group.lambda.id
}
