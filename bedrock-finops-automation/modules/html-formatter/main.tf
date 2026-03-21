# ============================================================
# modules/html-formatter
# コストレポートを HTML に整形して S3 に保存する Lambda
# ============================================================

data "aws_caller_identity" "current" {}

# ============================================================
# IAM Role
# ============================================================

resource "aws_iam_role" "html_formatter" {
  name = "${var.project_name}-html-formatter-${var.environment}"

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

resource "aws_iam_role_policy" "html_formatter" {
  name = "${var.project_name}-html-formatter-policy-${var.environment}"
  role = aws_iam_role.html_formatter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3: 各プレフィックスの読み取り + html/ への書き込み
      {
        Sid    = "S3ReportAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "${var.report_bucket_arn}/raw/*",
          "${var.report_bucket_arn}/anomaly/*",
          "${var.report_bucket_arn}/ai-report/*",
          "${var.report_bucket_arn}/html/*",
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

resource "aws_iam_role_policy_attachment" "html_formatter_basic_execution" {
  role       = aws_iam_role.html_formatter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================
# CloudWatch Logs Group
# ============================================================

resource "aws_cloudwatch_log_group" "html_formatter" {
  name              = "/aws/lambda/${var.project_name}-html-formatter-${var.environment}"
  retention_in_days = 30
}

# ============================================================
# Lambda Function
# ============================================================

data "archive_file" "html_formatter" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/html_formatter.zip"
}

resource "aws_lambda_function" "html_formatter" {
  function_name = "${var.project_name}-html-formatter-${var.environment}"
  role          = aws_iam_role.html_formatter.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout

  filename         = data.archive_file.html_formatter.output_path
  source_code_hash = data.archive_file.html_formatter.output_base64sha256

  environment {
    variables = {
      REPORT_BUCKET_NAME  = var.report_bucket_name
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      ENVIRONMENT         = var.environment
      PROJECT_NAME        = var.project_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.html_formatter,
    aws_iam_role_policy_attachment.html_formatter_basic_execution,
  ]
}
