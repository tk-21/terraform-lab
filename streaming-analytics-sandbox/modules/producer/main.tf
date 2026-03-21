# ---------------------------------------------------------------------------
# API Gateway REST → Kinesis Data Streams 直接統合
#
# 学習ポイント:
#   Lambda を一切使わず、VTL マッピングテンプレートで
#   API Gateway が直接 KDS の PutRecord API を呼ぶ。
#
# リクエストフロー:
#   POST /events (JSON body)
#     → VTL: { StreamName, Data: base64(body), PartitionKey: $.tenant_id }
#     → KDS PutRecord
#     → VTL: { event_id: SequenceNumber, shard_id: ShardId, status: "accepted" }
# ---------------------------------------------------------------------------

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ---------------------------------------------------------------------------
# IAM Role: API Gateway → KDS PutRecord
# ---------------------------------------------------------------------------

resource "aws_iam_role" "api_gateway_kinesis" {
  name = "${local.name_prefix}-apigw-kinesis-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "api_gateway_kinesis" {
  name = "kinesis-put-record"
  role = aws_iam_role.api_gateway_kinesis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kinesis:PutRecord"]
      Resource = var.kinesis_stream_arn
    }]
  })
}

# ---------------------------------------------------------------------------
# API Gateway REST API
# ---------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "this" {
  name        = "${local.name_prefix}-producer"
  description = "Event ingest API — POST /events directly to Kinesis Data Streams"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# /events リソース
resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "events"
}

# ---------------------------------------------------------------------------
# POST /events メソッド（API Key 必須）
# ---------------------------------------------------------------------------

resource "aws_api_gateway_method" "post_events" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.events.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

# ---------------------------------------------------------------------------
# AWS 統合: API Gateway → KDS PutRecord（VTL マッピングテンプレート）
# ---------------------------------------------------------------------------

resource "aws_api_gateway_integration" "kinesis_put_record" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.post_events.http_method
  type                    = "AWS"
  integration_http_method = "POST"

  # Kinesis PutRecord の URI
  uri         = "arn:aws:apigateway:${var.aws_region}:kinesis:action/PutRecord"
  credentials = aws_iam_role.api_gateway_kinesis.arn

  # リクエスト変換: JSON body → KDS PutRecord 形式
  request_templates = {
    "application/json" = <<-EOT
      {
        "StreamName": "${var.kinesis_stream_name}",
        "Data": "$util.base64Encode($input.body)",
        "PartitionKey": "$util.escapeJavaScript($input.path('$.tenant_id'))"
      }
    EOT
  }

  passthrough_behavior = "NEVER"
}

# ---------------------------------------------------------------------------
# メソッドレスポンス / 統合レスポンス
# ---------------------------------------------------------------------------

resource "aws_api_gateway_method_response" "post_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "post_200" {
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.events.id
  http_method       = aws_api_gateway_method.post_events.http_method
  status_code       = aws_api_gateway_method_response.post_200.status_code
  selection_pattern = "2[0-9][0-9]"

  # KDS レスポンス → フラットな JSON に変換
  response_templates = {
    "application/json" = <<-EOT
      {
        "event_id":  "$input.path('$.SequenceNumber')",
        "shard_id":  "$input.path('$.ShardId')",
        "status":    "accepted"
      }
    EOT
  }

  depends_on = [aws_api_gateway_integration.kinesis_put_record]
}

resource "aws_api_gateway_method_response" "post_400" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = "400"
}

resource "aws_api_gateway_integration_response" "post_400" {
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.events.id
  http_method       = aws_api_gateway_method.post_events.http_method
  status_code       = aws_api_gateway_method_response.post_400.status_code
  selection_pattern = "4[0-9][0-9]"

  response_templates = {
    "application/json" = "{\"message\": \"Bad Request\"}"
  }

  depends_on = [aws_api_gateway_integration.kinesis_put_record]
}

resource "aws_api_gateway_method_response" "post_500" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = "500"
}

resource "aws_api_gateway_integration_response" "post_500" {
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.events.id
  http_method       = aws_api_gateway_method.post_events.http_method
  status_code       = aws_api_gateway_method_response.post_500.status_code
  selection_pattern = "5[0-9][0-9]"

  response_templates = {
    "application/json" = "{\"message\": \"Internal Server Error\"}"
  }

  depends_on = [aws_api_gateway_integration.kinesis_put_record]
}

# ---------------------------------------------------------------------------
# デプロイメント & ステージ
# ---------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.events,
      aws_api_gateway_method.post_events,
      aws_api_gateway_integration.kinesis_put_record,
      aws_api_gateway_integration_response.post_200,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.environment

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      caller         = "$context.identity.caller"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      errorMessage   = "$context.error.message"
    })
  }

  xray_tracing_enabled = true
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name_prefix}-producer"
  retention_in_days = 14
}

# ---------------------------------------------------------------------------
# API Key & Usage Plan
# ---------------------------------------------------------------------------

resource "aws_api_gateway_api_key" "this" {
  name    = "${local.name_prefix}-events-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "this" {
  name = "${local.name_prefix}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = 100  # requests/second
    burst_limit = 200
  }
}

resource "aws_api_gateway_usage_plan_key" "this" {
  key_id        = aws_api_gateway_api_key.this.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}
