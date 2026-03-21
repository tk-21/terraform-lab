output "github_actions_role_arn" {
  description = "GitHub Actions OIDC IAM ロール ARN（GitHub Secrets の AWS_ROLE_ARN に設定する）"
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "GitHub Actions OIDC Provider ARN"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}
