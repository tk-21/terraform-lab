locals {
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  queue_name = var.input_queue_name
}

# -----------------------------------------------------------------
# IAM Role: API Gateway が SQS / DynamoDB を呼ぶための権限
# Lambda を経由しないため、API Gateway 自身に権限を付与する
# -----------------------------------------------------------------
resource "aws_iam_role" "api_gateway" {
  name = "${local.name_prefix}-apigw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "api_gateway" {
  name = "${local.name_prefix}-apigw-policy"
  role = aws_iam_role.api_gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # SQS: POST /jobs → SQS SendMessage
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = var.input_queue_arn
      },
      # DynamoDB: GET /jobs/{jobId} → DynamoDB GetItem
      {
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = var.jobs_table_arn
      },
      # CloudWatch Logs: API Gateway アクセスログ
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------
# CloudWatch Log Group for API Gateway access logs
# -----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = 14
}

# -----------------------------------------------------------------
# API Gateway REST API
# HTTP API (v2) は AWS サービス統合をサポートしないため REST API (v1) を使用
# -----------------------------------------------------------------
resource "aws_api_gateway_rest_api" "main" {
  name        = "${local.name_prefix}-api"
  description = "Event-driven pipeline API. POST /jobs → SQS, GET /jobs/{jobId} → DynamoDB (no Lambda)"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

# -----------------------------------------------------------------
# /jobs リソース
# -----------------------------------------------------------------
resource "aws_api_gateway_resource" "jobs" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "jobs"
}

# -----------------------------------------------------------------
# POST /jobs → SQS SendMessage（直接統合、Lambda 不要）
# マッピングテンプレート（VTL）でリクエストを SQS 形式に変換する
# -----------------------------------------------------------------
resource "aws_api_gateway_method" "post_jobs" {
  rest_api_id      = aws_api_gateway_rest_api.main.id
  resource_id      = aws_api_gateway_resource.jobs.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "post_jobs_sqs" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.jobs.id
  http_method             = aws_api_gateway_method.post_jobs.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:sqs:path/${data.aws_caller_identity.current.account_id}/${local.queue_name}"
  credentials             = aws_iam_role.api_gateway.arn

  # VTL でリクエストボディを SQS SendMessage 形式に変換
  # MessageBody にリクエストボディ全体を渡し、
  # MessageAttribute で Content-Type を付与する
  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
  }

  passthrough_behavior = "NEVER"
}

resource "aws_api_gateway_method_response" "post_jobs_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.post_jobs.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_method_response" "post_jobs_400" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.post_jobs.http_method
  status_code = "400"
}

resource "aws_api_gateway_integration_response" "post_jobs_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.post_jobs.http_method
  status_code = aws_api_gateway_method_response.post_jobs_200.status_code

  # SQS レスポンスの XML を JSON に変換して返す
  # job_id = SQS MessageId（Dispatcher Lambda が同じ値を DynamoDB の job_id として使用）
  response_templates = {
    "application/json" = <<-EOT
      #set($inputRoot = $input.path('$'))
      {
        "message": "Job accepted",
        "job_id": "$inputRoot.SendMessageResponse.SendMessageResult.MessageId"
      }
    EOT
  }

  depends_on = [aws_api_gateway_integration.post_jobs_sqs]
}

# -----------------------------------------------------------------
# /jobs/{jobId} リソース
# -----------------------------------------------------------------
resource "aws_api_gateway_resource" "job_id" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.jobs.id
  path_part   = "{jobId}"
}

# -----------------------------------------------------------------
# GET /jobs/{jobId} → DynamoDB GetItem（直接統合、Lambda 不要）
# -----------------------------------------------------------------
resource "aws_api_gateway_method" "get_job" {
  rest_api_id      = aws_api_gateway_rest_api.main.id
  resource_id      = aws_api_gateway_resource.job_id.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = true

  request_parameters = {
    "method.request.path.jobId" = true
  }
}

resource "aws_api_gateway_integration" "get_job_dynamodb" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.job_id.id
  http_method             = aws_api_gateway_method.get_job.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:dynamodb:action/GetItem"
  credentials             = aws_iam_role.api_gateway.arn

  request_templates = {
    "application/json" = jsonencode({
      TableName = var.jobs_table_name
      Key = {
        job_id = {
          "S" = "$input.params('jobId')"
        }
      }
    })
  }

  passthrough_behavior = "WHEN_NO_TEMPLATES"
}

resource "aws_api_gateway_method_response" "get_job_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.job_id.id
  http_method = aws_api_gateway_method.get_job.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_method_response" "get_job_404" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.job_id.id
  http_method = aws_api_gateway_method.get_job.http_method
  status_code = "404"
}

resource "aws_api_gateway_integration_response" "get_job_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.job_id.id
  http_method = aws_api_gateway_method.get_job.http_method
  status_code = aws_api_gateway_method_response.get_job_200.status_code

  # DynamoDB の型付き JSON レスポンスをフラットな JSON に変換する VTL
  response_templates = {
    "application/json" = <<-EOT
      #set($inputRoot = $input.path('$.Item'))
      #if($inputRoot == "")
        #set($context.responseOverride.status = 404)
        {"message": "Job not found"}
      #else
        {
          "job_id":     "$inputRoot.job_id.S",
          "tenant_id":  "$inputRoot.tenant_id.S",
          "status":     "$inputRoot.status.S",
          "complexity": "$inputRoot.complexity.S",
          "created_at": "$inputRoot.created_at.S"
          #if($inputRoot.result)
            ,"result":     "$util.escapeJavaScript($inputRoot.result.S)"
          #end
          #if($inputRoot.model_used)
            ,"model_used": "$inputRoot.model_used.S"
          #end
          #if($inputRoot.error_message)
            ,"error_message": "$inputRoot.error_message.S"
          #end
        }
      #end
    EOT
  }

  depends_on = [aws_api_gateway_integration.get_job_dynamodb]
}

# -----------------------------------------------------------------
# Deployment & Stage
# -----------------------------------------------------------------
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.post_jobs_sqs,
      aws_api_gateway_integration.get_job_dynamodb,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration_response.post_jobs_200,
    aws_api_gateway_integration_response.get_job_200,
  ]
}

resource "aws_api_gateway_stage" "main" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  deployment_id = aws_api_gateway_deployment.main.id
  stage_name    = var.stage_name

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      integrationError = "$context.integration.error"
    })
  }

  xray_tracing_enabled = true

  tags = {
    Name = "${local.name_prefix}-stage-${var.stage_name}"
  }
}

# API メソッドのメトリクスを詳細化
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
    logging_level   = "INFO"
  }
}

# -----------------------------------------------------------------
# API Key + Usage Plan（認証: X-API-Key ヘッダーが必要）
# -----------------------------------------------------------------
resource "aws_api_gateway_api_key" "client" {
  name    = "${local.name_prefix}-api-key"
  enabled = true

  tags = {
    Name = "${local.name_prefix}-api-key"
  }
}

resource "aws_api_gateway_usage_plan" "main" {
  name = "${local.name_prefix}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.main.id
    stage  = aws_api_gateway_stage.main.stage_name
  }

  tags = {
    Name = "${local.name_prefix}-usage-plan"
  }
}

resource "aws_api_gateway_usage_plan_key" "main" {
  key_id        = aws_api_gateway_api_key.client.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.main.id
}
