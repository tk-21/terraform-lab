data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  tags       = merge(var.tags, { Module = "bounce-pipeline" })
}

# ============================================================
# SNS Topics（バウンス・苦情通知）
# ============================================================

resource "aws_sns_topic" "bounce" {
  # バウンス通知をSNSに集約する理由:
  # LambdaをSESに直接連携するよりSNSを挟むことで Fan-out パターンが実現できる
  # 将来的にメール通知・Slack通知・S3ログ保存など複数の処理へ分岐可能
  name              = "mail-handson-bounce-topic"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.tags
}

resource "aws_sns_topic" "complaint" {
  # 苦情（スパム報告）通知用トピック
  # バウンスと別トピックにすることで、アラートしきい値や処理ロジックを独立して管理できる
  name              = "mail-handson-complaint-topic"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.tags
}

resource "aws_sns_topic_policy" "bounce" {
  arn = aws_sns_topic.bounce.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSESPublish"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.bounce.arn
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_sns_topic_policy" "complaint" {
  arn = aws_sns_topic.complaint.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSESPublish"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.complaint.arn
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

# ============================================================
# DynamoDB テーブル（サプレッションリスト）
# ============================================================

resource "aws_dynamodb_table" "suppression_list" {
  # サプレッションリスト: バウンス・苦情のあったアドレスへの再送信を防ぐテーブル
  # SESはバウンス率 > 5%、苦情率 > 0.1% でアカウントを自動停止するため
  # このリストを参照して事前に送信をスキップする運用が重要
  name         = "mail-handson-suppression-list"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "email"
  range_key    = "reason"

  attribute {
    name = "email"
    type = "S"
  }

  attribute {
    name = "reason"
    type = "S"
  }

  ttl {
    # ハードバウンス・苦情: TTLなし（永続記録）
    # ソフトバウンス: 30日後に自動削除（一時的エラーなので再挑戦を許容）
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = local.tags
}

# ============================================================
# IAM Role（bounce_handler Lambda用）
# ============================================================

resource "aws_iam_role" "bounce_lambda" {
  # IAMロール名は64文字以内（現在: 34文字）
  name = "mail-handson-bounce-lambda-role"

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

resource "aws_iam_role_policy" "bounce_lambda_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.bounce_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/mail-handson-bounce-handler:*"
    }]
  })
}

resource "aws_iam_role_policy" "bounce_lambda_dynamodb" {
  # DynamoDB権限: サプレッションリストへの書き込みのみ（最小権限）
  name = "dynamodb-suppression"
  role = aws_iam_role.bounce_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
      Resource = aws_dynamodb_table.suppression_list.arn
    }]
  })
}

resource "aws_iam_role_policy" "bounce_lambda_xray" {
  name = "xray-tracing"
  role = aws_iam_role.bounce_lambda.id
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
# Lambda Function（bounce_handler）
# ============================================================

data "archive_file" "bounce_handler" {
  type        = "zip"
  source_file = "${path.module}/lambda/bounce_handler.py"
  output_path = "${path.module}/lambda/bounce_handler.zip"
}

resource "aws_lambda_function" "bounce_handler" {
  function_name    = "mail-handson-bounce-handler"
  role             = aws_iam_role.bounce_lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "bounce_handler.lambda_handler"
  filename         = data.archive_file.bounce_handler.output_path
  source_code_hash = data.archive_file.bounce_handler.output_base64sha256
  timeout          = 30
  memory_size      = 128

  layers = [
    "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:${var.powertools_layer_version}"
  ]

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "bounce-handler"
      POWERTOOLS_LOG_LEVEL    = "INFO"
      AWS_LAMBDA_LOG_FORMAT   = "JSON"
      DYNAMODB_TABLE_NAME     = aws_dynamodb_table.suppression_list.name
    }
  }

  tracing_config { mode = "Active" }

  tags = local.tags
}

resource "aws_lambda_permission" "bounce_sns" {
  statement_id  = "AllowBounceTopicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bounce_handler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.bounce.arn
}

resource "aws_lambda_permission" "complaint_sns" {
  statement_id  = "AllowComplaintTopicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bounce_handler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.complaint.arn
}

resource "aws_sns_topic_subscription" "bounce_lambda" {
  topic_arn = aws_sns_topic.bounce.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.bounce_handler.arn
}

resource "aws_sns_topic_subscription" "complaint_lambda" {
  topic_arn = aws_sns_topic.complaint.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.bounce_handler.arn
}
