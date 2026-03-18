locals {
  name_prefix = "${var.project}-${var.environment}"
}

# -----------------------------------------------------------------
# CloudWatch Log Group: アクセスログ
# -----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-apigw-access-logs"
  }
}

# -----------------------------------------------------------------
# WAF v2 WebACL（REGIONAL: API Gateway 用）
# -----------------------------------------------------------------
resource "aws_wafv2_web_acl" "main" {
  name  = "${local.name_prefix}-waf"
  scope = "REGIONAL"

  default_action { allow {} }

  # OWASP Top 10 共通ルールセット
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-common"
      sampled_requests_enabled   = true
    }
  }

  # 既知の悪意あるリクエストパターン（SQLi / XSS 等）
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # IP ベースレート制限（5分間で上限超過 → ブロック）
  rule {
    name     = "RateLimitPerIP"
    priority = 3
    action { block {} }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.name_prefix}-waf"
  }
}

# -----------------------------------------------------------------
# HTTP API (API Gateway v2)
# REST API より安価、Lambda との統合がシンプル
# -----------------------------------------------------------------
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "WAF-protected HTTP API for Bedrock AI Platform router"

  cors_configuration {
    allow_headers = ["content-type", "x-tenant-id", "authorization"]
    allow_methods = ["POST", "OPTIONS"]
    allow_origins = ["*"] # dev 環境: 全オリジン許可（本番では要制限）
    max_age       = 300
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

# -----------------------------------------------------------------
# Lambda インテグレーション（router-lambda）
# -----------------------------------------------------------------
resource "aws_apigatewayv2_integration" "router" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.router_lambda_invoke_arn
  payload_format_version = "2.0"
}

# -----------------------------------------------------------------
# ルート: POST /chat
# -----------------------------------------------------------------
resource "aws_apigatewayv2_route" "chat" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

# -----------------------------------------------------------------
# ステージ: $default（スロットリング + アクセスログ）
# -----------------------------------------------------------------
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = var.throttle_burst_limit
    throttling_rate_limit    = var.throttle_rate_limit
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_logs.arn
  }

  tags = {
    Name = "${local.name_prefix}-api-default-stage"
  }
}

# -----------------------------------------------------------------
# Lambda Permission: API Gateway → router Lambda
# -----------------------------------------------------------------
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.router_lambda_function_name
  principal     = "apigateway.amazonaws.com"
  # /chat ルートのみ許可（他ルートからの呼び出しを防ぐ）
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*/chat"
}

# -----------------------------------------------------------------
# WAF ↔ API Gateway ステージ の紐付け
# -----------------------------------------------------------------
resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = aws_apigatewayv2_stage.default.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}
