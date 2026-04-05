# =============================================================================
# api モジュール
#
# 役割:
#   レビュー依頼の受付口となる API Gateway REST API を構築する。
#   Week 1: セッション作成 + S3 署名付き URL 発行（S3 アップロード用）
#   Week 2: Step Functions ステートマシン起動を追加予定
#
# エンドポイント設計:
#   POST /reviews        - レビューセッションを作成し S3 署名付き URL を返す
#   GET  /reviews/{id}   - セッションの進捗・結果を取得（Week 2 以降）
#
# フロー（Week 1）:
#   クライアント → POST /reviews → Lambda (session-handler)
#                                 ├── DynamoDB: セッション作成
#                                 └── S3: 署名付き URL 生成（ファイルアップロード用）
#
# フロー（Week 2 追加予定）:
#   S3 PUT イベント or クライアントが /reviews/{id}/start を呼び出す
#   → Lambda → Step Functions: 並列レビュー開始
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  function_name = "${var.project_name}-session-handler-${var.environment}"
}

# =============================================================================
# Lambda パッケージ生成
# =============================================================================
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/lambda.zip"
}

# =============================================================================
# IAM ロール: Lambda 実行ロール
# =============================================================================
resource "aws_iam_role" "lambda_exec" {
  name = "${local.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB: セッションの作成・読み取り
resource "aws_iam_role_policy" "dynamodb_access" {
  name = "dynamodb-access-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = var.review_table_arn
      }
    ]
  })
}

# S3: 入力ファイルのアップロード用署名付き URL 生成
# PutObject のみ許可（最小権限）
resource "aws_iam_role_policy" "s3_presign" {
  name = "s3-presign-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${var.input_bucket_arn}/reviews/*"
      }
    ]
  })
}

# =============================================================================
# Lambda 関数: セッションハンドラー
# レビューセッション作成・S3 署名付き URL 発行
# =============================================================================
resource "aws_lambda_function" "session_handler" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  memory_size = 256 # セッション作成のみなので 256MB で十分
  timeout     = 30

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.review_table_name
      INPUT_BUCKET_NAME   = var.input_bucket_id
      AWS_REGION_NAME     = data.aws_region.current.name
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
}

# =============================================================================
# API Gateway REST API
# =============================================================================
resource "aws_api_gateway_rest_api" "main" {
  name        = "${var.project_name}-api-${var.environment}"
  description = "AWS インフラレビュー AI - レビュー投入 API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# /reviews リソース
resource "aws_api_gateway_resource" "reviews" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "reviews"
}

# POST /reviews メソッド（認証なし: 学習用途。本番では Cognito/API Key を追加）
resource "aws_api_gateway_method" "post_reviews" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.reviews.id
  http_method   = "POST"
  authorization = "NONE"
}

# Lambda 統合（POST /reviews → session-handler Lambda）
resource "aws_api_gateway_integration" "post_reviews" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.reviews.id
  http_method = aws_api_gateway_method.post_reviews.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY" # Lambda プロキシ統合（ペイロードをそのまま Lambda に渡す）
  uri                     = aws_lambda_function.session_handler.invoke_arn
}

# /reviews/{session_id} リソース（GET /reviews/{id} 用）
resource "aws_api_gateway_resource" "review_item" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_resource.reviews.id
  path_part   = "{session_id}"
}

# GET /reviews/{session_id} メソッド
resource "aws_api_gateway_method" "get_review" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.review_item.id
  http_method   = "GET"
  authorization = "NONE"

  # パスパラメータをリクエストパラメータとして明示
  request_parameters = {
    "method.request.path.session_id" = true
  }
}

# Lambda 統合（GET /reviews/{session_id} → session-handler Lambda）
resource "aws_api_gateway_integration" "get_review" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.review_item.id
  http_method = aws_api_gateway_method.get_review.http_method

  integration_http_method = "POST" # Lambda プロキシ統合は常に POST
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.session_handler.invoke_arn
}

# API Gateway がこの Lambda を呼び出すことを許可
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.session_handler.function_name
  principal     = "apigateway.amazonaws.com"

  # 特定 API + メソッドからの呼び出しのみ許可（最小権限）
  source_arn = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

# API Gateway デプロイ
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  # メソッド・統合の変更を検知して再デプロイをトリガーする
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.reviews.id,
      aws_api_gateway_method.post_reviews.id,
      aws_api_gateway_integration.post_reviews.id,
      aws_api_gateway_resource.review_item.id,
      aws_api_gateway_method.get_review.id,
      aws_api_gateway_integration.get_review.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.post_reviews,
    aws_api_gateway_integration.get_review,
  ]
}

# ステージ（dev）
resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.environment

  # アクセスログを CloudWatch Logs に出力
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_logs.arn
  }

  # X-Ray トレーシング有効化（デバッグ・パフォーマンス分析）
  xray_tracing_enabled = true
}

resource "aws_cloudwatch_log_group" "api_gateway_logs" {
  name              = "/aws/api-gateway/${var.project_name}-${var.environment}"
  retention_in_days = 90
}

# API Gateway アカウント設定（CloudWatch Logs への書き込み権限）
resource "aws_iam_role" "api_gateway_cloudwatch" {
  name = "${var.project_name}-apigw-cw-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "apigateway.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  role       = aws_iam_role.api_gateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn
}
