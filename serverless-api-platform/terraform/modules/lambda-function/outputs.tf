# terraform/modules/lambda-function/outputs.tf

output "function_arn" {
  description = "Lambda 関数の ARN。API Gateway の統合設定・Lambda 呼び出し権限付与で使用する。"
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "Lambda 関数名。CloudWatch アラーム・デプロイスクリプトで使用する。"
  value       = aws_lambda_function.this.function_name
}

output "invoke_arn" {
  description = <<-EOT
    Lambda の呼び出し ARN。
    API Gateway の aws_lambda_permission と統合設定（integration_uri）で使用する。
    function_arn とは異なり region/account_id を含む形式になる。
  EOT
  value = aws_lambda_function.this.invoke_arn
}

output "role_arn" {
  description = "Lambda 実行ロールの ARN。execution_role_arn 指定時はその値、未指定時はモジュール内で作成したロールの ARN。"
  value       = local.effective_role_arn
}

output "role_name" {
  description = "Lambda 実行ロール名。execution_role_arn を指定した場合は null（外部ロール名は呼び出し元で管理する）。"
  value       = var.execution_role_arn == null ? aws_iam_role.this[0].name : null
}

output "log_group_name" {
  description = "CloudWatch Logs グループ名。ログ確認・サブスクリプションフィルター設定で使用する。"
  value       = aws_cloudwatch_log_group.this.name
}
