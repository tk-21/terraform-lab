output "lambda_role_arn" {
  description = "Lambda 実行ロールの ARN"
  value       = aws_iam_role.lambda_role.arn
}

output "lambda_role_name" {
  description = "Lambda 実行ロール名"
  value       = aws_iam_role.lambda_role.name
}
