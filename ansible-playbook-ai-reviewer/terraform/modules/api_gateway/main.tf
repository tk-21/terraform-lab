# Ansible AI Reviewer 用 REST API Gateway
# /review エンドポイントにPOSTでLambda Proxy統合
# APIキー認証・スロットリング・クォータを設定

# REST API本体
resource "aws_api_gateway_rest_api" "reviewer" {
  name        = var.api_name
  description = "Ansible Playbook AIレビュー用API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

# /review リソース
resource "aws_api_gateway_resource" "review" {
  rest_api_id = aws_api_gateway_rest_api.reviewer.id
  parent_id   = aws_api_gateway_rest_api.reviewer.root_resource_id
  path_part   = "review"
}

# POST /review メソッド（APIキー認証必須）
resource "aws_api_gateway_method" "post_review" {
  rest_api_id      = aws_api_gateway_rest_api.reviewer.id
  resource_id      = aws_api_gateway_resource.review.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

# Lambda Proxy統合
resource "aws_api_gateway_integration" "lambda_proxy" {
  rest_api_id             = aws_api_gateway_rest_api.reviewer.id
  resource_id             = aws_api_gateway_resource.review.id
  http_method             = aws_api_gateway_method.post_review.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
}

# デプロイ（メソッド・統合変更時に再デプロイが必要）
resource "aws_api_gateway_deployment" "reviewer" {
  rest_api_id = aws_api_gateway_rest_api.reviewer.id

  # メソッドや統合の変更を検知して再デプロイ
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.review.id,
      aws_api_gateway_method.post_review.id,
      aws_api_gateway_integration.lambda_proxy.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ステージ
resource "aws_api_gateway_stage" "reviewer" {
  deployment_id = aws_api_gateway_deployment.reviewer.id
  rest_api_id   = aws_api_gateway_rest_api.reviewer.id
  stage_name    = var.stage_name

  tags = var.tags
}

# APIキー
resource "aws_api_gateway_api_key" "reviewer" {
  name    = "ansible-ai-reviewer-key"
  enabled = true

  tags = var.tags
}

# Usage Plan（スロットリング・クォータ設定）
resource "aws_api_gateway_usage_plan" "reviewer" {
  name        = "ansible-ai-reviewer-plan"
  description = "Ansible AIレビュー用 Usage Plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.reviewer.id
    stage  = aws_api_gateway_stage.reviewer.stage_name
  }

  # スロットリング: 10 req/sec, バースト: 20
  throttle_settings {
    rate_limit  = 10
    burst_limit = 20
  }

  # クォータ: 1000回/月
  quota_settings {
    limit  = 1000
    period = "MONTH"
  }

  tags = var.tags
}

# APIキーとUsage Planを紐付け
resource "aws_api_gateway_usage_plan_key" "reviewer" {
  key_id        = aws_api_gateway_api_key.reviewer.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.reviewer.id
}

# API GatewayがLambdaを呼び出すためのパーミッション
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"

  # このAPIのすべてのステージ・メソッドからの呼び出しを許可
  source_arn = "${aws_api_gateway_rest_api.reviewer.execution_arn}/*/*"
}
