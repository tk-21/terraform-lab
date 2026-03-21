# ============================================================
# modules/collector
# Cost Explorer APIでコストデータを収集するLambda
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# IAM Role - Collector Lambda実行ロール
# ============================================================

resource "aws_iam_role" "collector" {
  name = "${var.project_name}-collector-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        # SourceAccount条件でConfused Deputy問題を防止
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# IAM Policy: 最小権限（必要なアクションのみ付与）
resource "aws_iam_role_policy" "collector" {
  name = "${var.project_name}-collector-policy-${var.environment}"
  role = aws_iam_role.collector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Cost Explorer: コストデータ取得のみ（リソースレベル制御非対応のため "*"）
      {
        Sid      = "CostExplorerRead"
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = ["*"]
      },
      # S3: rawプレフィックス配下への書き込みのみ
      {
        Sid    = "S3ReportWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
        ]
        Resource = ["${var.report_bucket_arn}/raw/*"]
      },
      # DynamoDB: 対象テーブルへのアイテム書き込みのみ
      {
        Sid    = "DynamoDBHistoryWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
        ]
        Resource = [var.dynamodb_table_arn]
      },
      # Secrets Manager: プロジェクト名プレフィックスのシークレットのみ取得可
      # （Chatwork APIトークンなど、他Lambdaと共通のパターン）
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/*"
        ]
      }
    ]
  })
}

# CloudWatch Logs書き込み権限（マネージドポリシーで付与）
resource "aws_iam_role_policy_attachment" "collector_basic_execution" {
  role       = aws_iam_role.collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================
# CloudWatch Logs Group
# ============================================================

resource "aws_cloudwatch_log_group" "collector" {
  name              = "/aws/lambda/${var.project_name}-collector-${var.environment}"
  retention_in_days = 30
}

# ============================================================
# Lambda Function
# ============================================================

# デプロイパッケージ（srcディレクトリをzip化）
data "archive_file" "collector" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/collector.zip"
}

resource "aws_lambda_function" "collector" {
  function_name = "${var.project_name}-collector-${var.environment}"
  role          = aws_iam_role.collector.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout

  filename         = data.archive_file.collector.output_path
  source_code_hash = data.archive_file.collector.output_base64sha256

  environment {
    variables = {
      REPORT_BUCKET_NAME  = var.report_bucket_name
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      ENVIRONMENT         = var.environment
      PROJECT_NAME        = var.project_name
    }
  }

  # ログ出力先グループが先に存在することを保証
  depends_on = [
    aws_cloudwatch_log_group.collector,
    aws_iam_role_policy_attachment.collector_basic_execution,
  ]
}
