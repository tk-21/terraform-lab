output "lambda_remediation_role_arn" {
  description = "Lambda修復実行ロールのARN (後続フェーズでLambda作成時に使用)"
  value       = aws_iam_role.lambda_remediation.arn
}

output "lambda_remediation_role_name" {
  description = "Lambda修復実行ロール名"
  value       = aws_iam_role.lambda_remediation.name
}

output "config_service_role_arn" {
  description = "Configサービスロール ARN"
  value       = aws_iam_role.config_service.arn
}

output "eventbridge_invoke_role_arn" {
  description = "EventBridgeターゲット実行ロール ARN"
  value       = aws_iam_role.eventbridge_invoke.arn
}
