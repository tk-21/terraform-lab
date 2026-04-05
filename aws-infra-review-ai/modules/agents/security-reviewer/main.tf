# =============================================================================
# security-reviewer エージェント
#
# 役割: AWS インフラのセキュリティ観点レビューを担当
# チェック観点:
#   - IAM 最小権限原則の遵守
#   - 保存・転送時の暗号化設定
#   - VPC エンドポイントの有無（プライベート通信）
#   - パブリック露出（S3 ACL, SG 0.0.0.0/0 等）
#   - Secrets の適切な管理（ハードコードされた認証情報検出）
#   - セキュリティグループの過剰開放
# =============================================================================

locals {
  function_name = "${var.project_name}-security-reviewer-${var.environment}"
  # Bedrock Claude 3.5 Sonnet（最新版）
  bedrock_model_arn = "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
}

# =============================================================================
# Lambda パッケージ（ZIP）生成
# src/index.py を ZIP 化して Lambda にデプロイ
# =============================================================================
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/lambda.zip"
}

# =============================================================================
# IAM ロール: Lambda 実行ロール
# Lambda が引き受けるロール（trust policy）
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

# CloudWatch Logs への書き込み（Lambda 基本実行権限）
resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# =============================================================================
# IAM ポリシー: Bedrock 呼び出し権限（最小権限）
# InvokeModel のみ許可、特定モデル ARN に限定
# =============================================================================
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

# =============================================================================
# IAM ポリシー: DynamoDB アクセス権限
# レビュー結果を書き込む・読み込む最小限の操作のみ許可
# =============================================================================
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

# =============================================================================
# Lambda 関数
# =============================================================================
resource "aws_lambda_function" "security_reviewer" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_exec.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # コスト最適化: 512MB / 60秒（CLAUDE.md 規定値）
  memory_size = 512
  timeout     = 60

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      BEDROCK_MODEL_ID    = "anthropic.claude-3-5-sonnet-20241022-v2:0"
      AGENT_NAME          = "security-reviewer"
    }
  }
}

# CloudWatch Logs グループ（90日保持でコスト最適化）
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
}
