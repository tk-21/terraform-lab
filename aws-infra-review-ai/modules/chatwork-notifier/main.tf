# =============================================================================
# chatwork-notifier モジュール
#
# 役割:
#   レビュー完了後に Chatwork ルームへ通知を送信する。
#   - 総合スコア（各エージェント別）
#   - エグゼクティブサマリー
#   - 優先対応アクション TOP 5
#   - HTML レポートリンク（7 日間有効の署名付き URL）
#
# Chatwork API トークンの保管:
#   SSM Parameter Store（SecureString）に格納し、
#   Lambda が実行時に取得する（環境変数へのハードコード禁止）。
#
# Step Functions のフロー上の位置:
#   GenerateReport → SendNotification（このLambda）→ UpdateStatusCompleted
# =============================================================================

locals {
  function_name = "${var.project_name}-chatwork-notifier-${var.environment}"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/lambda.zip"
}

# =============================================================================
# IAM ロール: chatwork-notifier Lambda 実行ロール
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

# SSM Parameter Store からの Chatwork API トークン取得権限
# GetParameter のみ許可（最小権限: 特定パスに限定）
resource "aws_iam_role_policy" "ssm_get_parameter" {
  name = "ssm-get-parameter-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:ap-northeast-1:*:parameter${var.chatwork_token_ssm_path}"
      }
    ]
  })
}

# =============================================================================
# Lambda 関数: chatwork-notifier
# SSM からトークン取得 → Chatwork API 呼び出し
# =============================================================================
resource "aws_lambda_function" "chatwork_notifier" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # Chatwork への HTTP リクエストのみなので 256MB で十分
  memory_size = 256
  timeout     = 30

  environment {
    variables = {
      CHATWORK_ROOM_ID          = var.chatwork_room_id
      CHATWORK_TOKEN_SSM_PATH   = var.chatwork_token_ssm_path
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
}
