# terraform/modules/cognito/outputs.tf

output "user_pool_id" {
  description = "Cognito User Pool ID。Lambda 環境変数や Amplify 設定で使用する。"
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN。API Gateway Cognito オーソライザーの設定に使用する。"
  value       = aws_cognito_user_pool.this.arn
}

output "client_id" {
  description = "App Client ID。SPA や Amplify からの認証リクエストで使用する。"
  value       = aws_cognito_user_pool_client.api.id
}

output "issuer_url" {
  description = <<-EOT
    JWT issuer URL。API Gateway Cognito オーソライザーの issuer に設定する。
    形式: https://cognito-idp.<region>.amazonaws.com/<user_pool_id>
    API Gateway はこの URL を基に JWKS エンドポイントへアクセスし、
    トークン署名を検証する。
  EOT
  value = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

# issuer_url の組み立てに使用するリージョン情報
data "aws_region" "current" {}
