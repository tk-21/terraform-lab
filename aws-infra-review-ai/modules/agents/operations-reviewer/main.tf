# =============================================================================
# operations-reviewer エージェント
#
# 役割: AWS インフラの運用性観点レビューを担当
# チェック観点:
#   - タグ戦略（Environment / Project / Owner / CostCenter の付与）
#   - 監視設計（CloudWatch アラーム・ダッシュボード・メトリクス）
#   - ログ出力（CloudTrail・VPC Flow Logs・アクセスログの有効化）
#   - デプロイ戦略（Blue/Green・カナリアリリース・ロールバック手順）
#   - ドリフト検知（Terraform State との乖離防止）
#   - インシデント対応（アラート通知先・エスカレーションパス）
# =============================================================================

locals {
  function_name     = "${var.project_name}-operations-reviewer-${var.environment}"
  bedrock_model_arn = "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/lambda.zip"
}

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

# DynamoDB アクセス権限（レビュー結果の書き込み）
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
          "dynamodb:UpdateItem",
          "dynamodb:PutItem"
        ]
        Resource = var.dynamodb_table_arn
      }
    ]
  })
}

resource "aws_lambda_function" "operations_reviewer" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  memory_size = 512
  timeout     = 60

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      BEDROCK_MODEL_ID    = "anthropic.claude-3-5-sonnet-20241022-v2:0"
      AGENT_NAME          = "operations-reviewer"
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
}
