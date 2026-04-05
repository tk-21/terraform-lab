# =============================================================================
# supervisor エージェント
#
# 役割:
#   security / cost / reliability / operations の 4 エージェントが出力した
#   レビュー結果を受け取り、トレードオフを明示した統合レビューを生成する。
#
# Step Functions のフロー上の位置:
#   ParallelReview（4 並列）→ SupervisorReview（このLambda）→ UpdateStatusCompleted
# =============================================================================

locals {
  function_name     = "${var.project_name}-supervisor-${var.environment}"
  bedrock_model_arn = "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/lambda.zip"
}

# =============================================================================
# IAM ロール: supervisor Lambda 実行ロール
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

# Bedrock 呼び出し権限（最小権限: InvokeModel のみ、特定モデルに限定）
resource "aws_iam_role_policy" "bedrock_invoke" {
  name = "bedrock-invoke-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = local.bedrock_model_arn
      }
    ]
  })
}

# DynamoDB アクセス権限（rounds.round_2 への統合結果書き込み）
resource "aws_iam_role_policy" "dynamodb_access" {
  name = "dynamodb-access-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = var.dynamodb_table_arn
      }
    ]
  })
}

# =============================================================================
# Lambda 関数: supervisor
# 4 エージェントの結果を統合・矛盾解消・トレードオフ明示
# =============================================================================
resource "aws_lambda_function" "supervisor" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # 4 エージェントの結果 + Bedrock 呼び出しがあるため 512MB に設定
  memory_size = 512
  timeout     = 60

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      BEDROCK_MODEL_ID    = "anthropic.claude-3-5-sonnet-20241022-v2:0"
      AGENT_NAME          = "supervisor"
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
}
