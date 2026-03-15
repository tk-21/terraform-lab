output "region" { value = var.region }
output "cluster_name" { value = module.eks.cluster_name }

output "ecr_repo_url" { value = aws_ecr_repository.app.repository_url }
output "app_image" { value = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}" }

output "irsa_app_role_arn" { value = module.irsa_app.iam_role_arn }

output "knowledge_bucket" { value = aws_s3_bucket.knowledge.bucket }

output "knowledge_base_id" { value = try(aws_bedrockagent_knowledge_base.this.id, "") }
output "data_source_id" { value = try(aws_bedrockagent_data_source.s3.id, "") }

output "alb_logs_bucket" { value = try(aws_s3_bucket.alb_logs.bucket, "") }

# Cognito（使う場合）
output "cognito_user_pool_id" { value = try(aws_cognito_user_pool.this.id, "") }
output "cognito_client_id" { value = try(aws_cognito_user_pool_client.this.id, "") }
output "cognito_domain" { value = try(aws_cognito_user_pool_domain.this.domain, "") }
output "cognito_client_secret" {
  value     = try(aws_cognito_user_pool_client.this.client_secret, "")
  sensitive = true
}

# OIDC endpoints（Cognito Hosted UI想定）
output "oidc_issuer" {
  value = try("https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this.id}", "")
}
output "oidc_authorization_endpoint" {
  value = try("https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region}.amazoncognito.com/oauth2/authorize", "")
}
output "oidc_token_endpoint" {
  value = try("https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region}.amazoncognito.com/oauth2/token", "")
}
output "oidc_userinfo_endpoint" {
  value = try("https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region}.amazoncognito.com/oauth2/userInfo", "")
}
