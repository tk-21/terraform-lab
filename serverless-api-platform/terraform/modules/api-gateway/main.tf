# terraform/modules/api-gateway/main.tf
#
# API Gateway REST API の設定。
# REST API (v1) を使用する理由は docs/adr/003-rest-vs-http-api.md を参照。
# HTTP API (v2) の方が安価だが、リクエストバリデーション等の機能が REST API にしかない。

resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.prefix}-api"
  description = "Serverless API Platform REST API (${var.environment})"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# ============================================================
# /items リソース
# ============================================================
resource "aws_api_gateway_resource" "items" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "items"
}

# /items/{id} リソース
resource "aws_api_gateway_resource" "item" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.items.id
  path_part   = "{id}"
}

# ============================================================
# GET /items → list-items Lambda
# ============================================================
module "get_items_method" {
  source = "./method"

  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.items.id
  http_method        = "GET"
  lambda_invoke_arn  = var.lambda_arns["list_items"]
  authorization_type = var.cognito_user_pool_arn != null ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id      = var.cognito_user_pool_arn != null ? aws_api_gateway_authorizer.cognito[0].id : null
}

# ============================================================
# POST /items → create-item Lambda
# ============================================================
module "post_items_method" {
  source = "./method"

  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.items.id
  http_method        = "POST"
  lambda_invoke_arn  = var.lambda_arns["create_item"]
  authorization_type = var.cognito_user_pool_arn != null ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id      = var.cognito_user_pool_arn != null ? aws_api_gateway_authorizer.cognito[0].id : null
}

# ============================================================
# GET /items/{id} → get-item Lambda
# ============================================================
module "get_item_method" {
  source = "./method"

  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.item.id
  http_method        = "GET"
  lambda_invoke_arn  = var.lambda_arns["get_item"]
  authorization_type = var.cognito_user_pool_arn != null ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id      = var.cognito_user_pool_arn != null ? aws_api_gateway_authorizer.cognito[0].id : null
}

# ============================================================
# PUT /items/{id} → update-item Lambda
# ============================================================
module "put_item_method" {
  source = "./method"

  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.item.id
  http_method        = "PUT"
  lambda_invoke_arn  = var.lambda_arns["update_item"]
  authorization_type = var.cognito_user_pool_arn != null ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id      = var.cognito_user_pool_arn != null ? aws_api_gateway_authorizer.cognito[0].id : null
}

# ============================================================
# DELETE /items/{id} → delete-item Lambda
# ============================================================
module "delete_item_method" {
  source = "./method"

  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.item.id
  http_method        = "DELETE"
  lambda_invoke_arn  = var.lambda_arns["delete_item"]
  authorization_type = var.cognito_user_pool_arn != null ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id      = var.cognito_user_pool_arn != null ? aws_api_gateway_authorizer.cognito[0].id : null
}

# ============================================================
# Cognito オーソライザー
# ============================================================
# Cognito のトークン検証を API Gateway に委譲する。
# Lambda 側でトークン検証を実装してはならない（CLAUDE.md の禁止事項）。
resource "aws_api_gateway_authorizer" "cognito" {
  count = var.cognito_user_pool_arn != null ? 1 : 0

  name            = "${var.prefix}-cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.this.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [var.cognito_user_pool_arn]
  identity_source = "method.request.header.Authorization"
}

# ============================================================
# デプロイメントとステージ
# ============================================================
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # メソッド変更時に再デプロイするためのトリガー
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.items.id,
      aws_api_gateway_resource.item.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.environment

  # アクセスログの有効化
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
  }

  # X-Ray トレーシングの有効化
  xray_tracing_enabled = true
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${var.prefix}-api"
  retention_in_days = 14
}
