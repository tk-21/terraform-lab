# =============================================================================
# report-generator モジュール
#
# 役割:
#   4 エージェント + supervisor の結果を受け取り、
#   HTML レポートを生成して S3 に保存する。
#   DynamoDB の final_report_url を更新し、
#   7 日間有効の署名付き URL をワークフローに返す。
#
# Step Functions のフロー上の位置:
#   SupervisorReview → GenerateReport（このLambda）→ SendNotification
# =============================================================================

locals {
  function_name = "${var.project_name}-report-generator-${var.environment}"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/lambda.zip"
}

# =============================================================================
# IAM ロール: report-generator Lambda 実行ロール
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

# S3 レポートバケットへの書き込み + 署名付き URL 生成権限
resource "aws_iam_role_policy" "s3_reports" {
  name = "s3-reports-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject", # 署名付き URL の生成に必要（GetObject のアクセス権限を委譲するため）
        ]
        Resource = "${var.reports_bucket_arn}/reports/*"
      }
    ]
  })
}

# DynamoDB final_report_url の更新権限
resource "aws_iam_role_policy" "dynamodb_access" {
  name = "dynamodb-access-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = var.dynamodb_table_arn
      }
    ]
  })
}

# =============================================================================
# Lambda 関数: report-generator
# HTML レポート生成 + S3 保存 + 署名付き URL 発行
# =============================================================================
resource "aws_lambda_function" "report_generator" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # HTML 生成は CPU/メモリを使わないため 256MB で十分
  memory_size = 256
  timeout     = 30

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      REPORTS_BUCKET_NAME = var.reports_bucket_id
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
}
