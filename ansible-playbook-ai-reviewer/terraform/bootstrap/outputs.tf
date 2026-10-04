output "role_arn" {
  description = "GitHub の Secrets に AWS_ROLE_ARN として登録する IAM ロールの ARN"
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "使用している GitHub OIDC プロバイダの ARN"
  value       = local.oidc_provider_arn
}
