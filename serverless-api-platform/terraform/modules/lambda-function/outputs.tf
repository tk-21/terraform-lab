# terraform/modules/lambda-function/outputs.tf

output "function_arn" {
  description = "Lambda 関数の ARN。API Gateway の統合設定で使用する。"
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "Lambda 関数名。モニタリング・デプロイスクリプトで使用する。"
  value       = aws_lambda_function.this.function_name
}

output "invoke_arn" {
  description = "Lambda の呼び出し ARN。API Gateway の統合設定で使用する。"
  value       = aws_lambda_function.this.invoke_arn
}

output "log_group_name" {
  description = "CloudWatch Logs グループ名。ログ確認時に使用する。"
  value       = aws_cloudwatch_log_group.this.name
}
