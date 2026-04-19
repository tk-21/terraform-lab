output "api_endpoint" {
  description = "Ansible AIレビューAPIのエンドポイントURL"
  value       = module.api_gateway.api_endpoint
}

output "lambda_function_name" {
  description = "Lambda関数名"
  value       = module.reviewer_lambda.lambda_function_name
}

output "reviewer_role_arn" {
  description = "Lambda実行ロールのARN"
  value       = aws_iam_role.reviewer.arn
}
