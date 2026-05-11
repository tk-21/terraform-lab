# シナリオ3 Lambda が ECS Service を更新するための最小権限ロール
resource "aws_iam_role" "lambda_desired_count" {
  name = "${var.prefix}-lambda-desired-count-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lambda_desired_count" {
  name = "${var.prefix}-lambda-desired-count-policy"
  role = aws_iam_role.lambda_desired_count.id

  policy = jsonencode({
    Statement = [
      {
        # ECS Service の DesiredCount 変更のみ許可
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${var.cluster_name}/${var.service_name}"
      },
      {
        # Lambda ログ書き込み
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/${var.prefix}-desired-count-changer:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_desired_count.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# lambda_src/ をその場で zip 化して Lambda にデプロイ。
# ECR/S3 不要でシンプルな構成。FIS 専用の小さな関数のため inline zip で十分。
data "archive_file" "desired_count_changer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src"
  output_path = "${path.module}/.lambda_build/desired_count_changer.zip"
}

resource "aws_lambda_function" "desired_count_changer" {
  function_name    = "${var.prefix}-desired-count-changer"
  role             = aws_iam_role.lambda_desired_count.arn
  runtime          = "python3.12"
  handler          = "desired_count_changer.lambda_handler"
  filename         = data.archive_file.desired_count_changer.output_path
  source_code_hash = data.archive_file.desired_count_changer.output_base64sha256
  timeout          = 30
  architectures    = ["arm64"] # コスト最適化（Graviton2）

  environment {
    variables = {
      CLUSTER_NAME  = var.cluster_name
      SERVICE_NAME  = var.service_name
      TARGET_COUNT  = "0"
      RESTORE_COUNT = "2"
    }
  }

  tags = var.tags
}

# FIS が Lambda を invoke できるようリソースベースポリシーを追加
resource "aws_lambda_permission" "fis_invoke" {
  statement_id  = "AllowFISInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.desired_count_changer.function_name
  principal     = "fis.amazonaws.com"
  source_arn    = "arn:aws:fis:${var.aws_region}:${var.account_id}:experiment-template/*"
}
