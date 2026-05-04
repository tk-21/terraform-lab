data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  tags       = merge(var.tags, { Module = "suppression-sync" })
}

# ============================================================
# IAM Role（suppression_mgr Lambda用）
# ============================================================

resource "aws_iam_role" "suppression_mgr" {
  # IAMロール名は64文字以内（現在: 32文字）
  name = "mail-handson-suppression-mgr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "suppression_mgr_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.suppression_mgr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/mail-handson-suppression-mgr:*"
    }]
  })
}

resource "aws_iam_role_policy" "suppression_mgr_dynamodb" {
  # DynamoDB権限: サプレッションリストの読み取りとTTL切れアイテムの削除
  name = "dynamodb-suppression"
  role = aws_iam_role.suppression_mgr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:Scan", "dynamodb:GetItem", "dynamodb:DeleteItem"]
      Resource = var.suppression_table_arn
    }]
  })
}

resource "aws_iam_role_policy" "suppression_mgr_ses" {
  # SESサプレッションリスト管理権限
  # list: DynamoDBと差分比較するために既存エントリ一覧が必要
  # put/delete: DynamoDBとの差分を同期する
  name = "ses-suppression"
  role = aws_iam_role.suppression_mgr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:ListSuppressedDestinations", "ses:PutSuppressedDestination", "ses:DeleteSuppressedDestination"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "suppression_mgr_cloudwatch" {
  name = "cloudwatch-metrics"
  role = aws_iam_role.suppression_mgr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["cloudwatch:PutMetricData"]
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = "MailInfraHandson" } }
    }]
  })
}

resource "aws_iam_role_policy" "suppression_mgr_xray" {
  name = "xray-tracing"
  role = aws_iam_role.suppression_mgr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource = "*"
    }]
  })
}

# ============================================================
# Lambda Function（suppression_manager）
# ============================================================

data "archive_file" "suppression_mgr" {
  type        = "zip"
  source_file = "${path.module}/lambda/suppression_manager.py"
  output_path = "${path.module}/lambda/suppression_manager.zip"
}

resource "aws_lambda_function" "suppression_mgr" {
  # DynamoDB（アプリレベル）とSES（アカウントレベル）のサプレッションリストを同期する
  function_name    = "mail-handson-suppression-mgr"
  role             = aws_iam_role.suppression_mgr.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "suppression_manager.lambda_handler"
  filename         = data.archive_file.suppression_mgr.output_path
  source_code_hash = data.archive_file.suppression_mgr.output_base64sha256
  timeout          = 300
  memory_size      = 256

  layers = [
    "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:${var.powertools_layer_version}"
  ]

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "suppression-mgr"
      POWERTOOLS_LOG_LEVEL    = "INFO"
      AWS_LAMBDA_LOG_FORMAT   = "JSON"
      SUPPRESSION_TABLE_NAME  = var.suppression_table_name
    }
  }

  tracing_config { mode = "Active" }

  tags = local.tags
}

# ============================================================
# EventBridge スケジュール（毎日AM2時 JST）
# ============================================================

resource "aws_iam_role" "scheduler" {
  name = "mail-handson-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "invoke-suppression-mgr"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.suppression_mgr.arn
    }]
  })
}

resource "aws_scheduler_schedule" "daily" {
  # 毎日AM2時（JST = UTC 17:00前日）にサプレッションリスト同期を実行
  # 深夜バッチとして実行することでメール送信ピーク時間帯の影響を避ける
  name       = "mail-handson-suppression-sync"
  group_name = "default"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 15
  }

  schedule_expression          = "cron(0 17 * * ? *)"
  schedule_expression_timezone = "Asia/Tokyo"

  target {
    arn      = aws_lambda_function.suppression_mgr.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
