# ============================================================
# modules/chatwork-notifier
# 月次コストレポートの要約を Chatwork に通知する Lambda
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# IAM Role
# ============================================================

resource "aws_iam_role" "chatwork_notifier" {
  name = "${var.project_name}-chatwork-notifier-${var.environment}"

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

resource "aws_iam_role_policy" "chatwork_notifier" {
  name = "${var.project_name}-chatwork-notifier-policy-${var.environment}"
  role = aws_iam_role.chatwork_notifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Secrets Manager: Chatwork API トークンのみ取得可（プロジェクト名プレフィックスでスコープ制限）
      {
        Sid    = "SecretsManagerChatworkToken"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.chatwork_api_token_secret_name}*"
        ]
      },
      # SSM Parameter Store: Chatwork ルーム ID のみ取得可
      {
        Sid    = "SSMChatworkRoomId"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.chatwork_room_id_parameter_name}"
        ]
      },
      # S3: HTML レポートへの読み取り（署名付き URL 生成のため GetObject が必要）
      {
        Sid    = "S3HtmlReportRead"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = ["${var.report_bucket_arn}/html/*"]
      },
      # DynamoDB: 最終ステータス更新
      {
        Sid    = "DynamoDBFinalUpdate"
        Effect = "Allow"
        Action = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [var.dynamodb_table_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "chatwork_notifier_basic_execution" {
  role       = aws_iam_role.chatwork_notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================
# CloudWatch Logs Group
# ============================================================

resource "aws_cloudwatch_log_group" "chatwork_notifier" {
  name              = "/aws/lambda/${var.project_name}-chatwork-notifier-${var.environment}"
  retention_in_days = 30
}

# ============================================================
# Lambda Function
# ============================================================

data "archive_file" "chatwork_notifier" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/chatwork_notifier.zip"
}

resource "aws_lambda_function" "chatwork_notifier" {
  function_name = "${var.project_name}-chatwork-notifier-${var.environment}"
  role          = aws_iam_role.chatwork_notifier.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout

  filename         = data.archive_file.chatwork_notifier.output_path
  source_code_hash = data.archive_file.chatwork_notifier.output_base64sha256

  environment {
    variables = {
      REPORT_BUCKET_NAME                   = var.report_bucket_name
      DYNAMODB_TABLE_NAME                  = var.dynamodb_table_name
      ENVIRONMENT                          = var.environment
      PROJECT_NAME                         = var.project_name
      CHATWORK_API_TOKEN_SECRET_NAME       = var.chatwork_api_token_secret_name
      CHATWORK_ROOM_ID_PARAMETER_NAME      = var.chatwork_room_id_parameter_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.chatwork_notifier,
    aws_iam_role_policy_attachment.chatwork_notifier_basic_execution,
  ]
}
