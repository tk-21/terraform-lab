# ============================================================
# modules/anomaly-detector
# 前月比・スパイク・サービス集中度の異常検知 Lambda
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# IAM Role - Anomaly Detector Lambda 実行ロール
# ============================================================

resource "aws_iam_role" "anomaly_detector" {
  name = "${var.project_name}-anomaly-detector-${var.environment}"

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

# IAM Policy: 最小権限
resource "aws_iam_role_policy" "anomaly_detector" {
  name = "${var.project_name}-anomaly-detector-policy-${var.environment}"
  role = aws_iam_role.anomaly_detector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3: raw/ の読み取り + anomaly/ への書き込み
      {
        Sid    = "S3ReportAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = [
          "${var.report_bucket_arn}/raw/*",
          "${var.report_bucket_arn}/anomaly/*",
        ]
      },
      # DynamoDB: レポートステータス更新
      {
        Sid    = "DynamoDBHistoryUpdate"
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem",
          "dynamodb:GetItem",
        ]
        Resource = [var.dynamodb_table_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "anomaly_detector_basic_execution" {
  role       = aws_iam_role.anomaly_detector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================
# CloudWatch Logs Group
# ============================================================

resource "aws_cloudwatch_log_group" "anomaly_detector" {
  name              = "/aws/lambda/${var.project_name}-anomaly-detector-${var.environment}"
  retention_in_days = 30
}

# ============================================================
# Lambda Function
# ============================================================

data "archive_file" "anomaly_detector" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/anomaly_detector.zip"
}

resource "aws_lambda_function" "anomaly_detector" {
  function_name = "${var.project_name}-anomaly-detector-${var.environment}"
  role          = aws_iam_role.anomaly_detector.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout

  filename         = data.archive_file.anomaly_detector.output_path
  source_code_hash = data.archive_file.anomaly_detector.output_base64sha256

  environment {
    variables = {
      REPORT_BUCKET_NAME              = var.report_bucket_name
      DYNAMODB_TABLE_NAME             = var.dynamodb_table_name
      ENVIRONMENT                     = var.environment
      PROJECT_NAME                    = var.project_name
      MEDIUM_THRESHOLD_PCT            = tostring(var.medium_threshold_pct)
      HIGH_THRESHOLD_PCT              = tostring(var.high_threshold_pct)
      SERVICE_CONCENTRATION_THRESHOLD = tostring(var.service_concentration_threshold_pct)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.anomaly_detector,
    aws_iam_role_policy_attachment.anomaly_detector_basic_execution,
  ]
}
