# ============================================================
# modules/ai-reporter
# Bedrock（Claude Haiku）で月次コストの AI 所見を生成する Lambda
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# IAM Role
# ============================================================

resource "aws_iam_role" "ai_reporter" {
  name = "${var.project_name}-ai-reporter-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ai_reporter" {
  name = "${var.project_name}-ai-reporter-policy-${var.environment}"
  role = aws_iam_role.ai_reporter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Bedrock: 指定モデルへの InvokeModel のみ許可（他モデル・他操作は禁止）
      {
        Sid    = "BedrockInvokeHaiku"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/${var.bedrock_model_id}"
        ]
      },
      # S3: 入力データ読み取り（raw/ anomaly/）+ AI レポート書き込み（ai-report/）
      {
        Sid    = "S3ReportAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "${var.report_bucket_arn}/raw/*",
          "${var.report_bucket_arn}/anomaly/*",
          "${var.report_bucket_arn}/ai-report/*",
        ]
      },
      # DynamoDB: ステータス更新
      {
        Sid    = "DynamoDBHistoryUpdate"
        Effect = "Allow"
        Action = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [var.dynamodb_table_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ai_reporter_basic_execution" {
  role       = aws_iam_role.ai_reporter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================
# CloudWatch Logs Group
# ============================================================

resource "aws_cloudwatch_log_group" "ai_reporter" {
  name              = "/aws/lambda/${var.project_name}-ai-reporter-${var.environment}"
  retention_in_days = 30
}

# ============================================================
# Lambda Function
# ============================================================

data "archive_file" "ai_reporter" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/ai_reporter.zip"
}

resource "aws_lambda_function" "ai_reporter" {
  function_name = "${var.project_name}-ai-reporter-${var.environment}"
  role          = aws_iam_role.ai_reporter.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout

  filename         = data.archive_file.ai_reporter.output_path
  source_code_hash = data.archive_file.ai_reporter.output_base64sha256

  environment {
    variables = {
      REPORT_BUCKET_NAME = var.report_bucket_name
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      ENVIRONMENT        = var.environment
      PROJECT_NAME       = var.project_name
      BEDROCK_MODEL_ID   = var.bedrock_model_id
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.ai_reporter,
    aws_iam_role_policy_attachment.ai_reporter_basic_execution,
  ]
}
