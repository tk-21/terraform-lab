resource "aws_cognito_user_pool" "this" {
  name = "${local.name}-pool"
  tags = local.tags
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${local.name}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls                = var.cognito_callback_urls
  supported_identity_providers = ["COGNITO"]
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${local.name}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}
