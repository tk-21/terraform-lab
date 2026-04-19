# Ansible Playbook AIレビュー用 Lambda関数
# Phase2でコードをデプロイするまでの仮placeholder zipを使用

# placeholder用のzipファイルをローカルで生成
data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder.zip"

  source {
    content  = "# Phase2でコードをデプロイします"
    filename = "index.py"
  }
}

# Lambda関数本体
resource "aws_lambda_function" "reviewer" {
  function_name = var.function_name
  role          = var.role_arn
  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "index.handler"
  timeout       = var.timeout
  memory_size   = var.memory

  # Phase2でコードを上書きデプロイするまでのplaceholder
  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  environment {
    variables = {
      GITHUB_TOKEN_SSM_PATH   = var.github_token_ssm_path
      BEDROCK_REGION          = var.bedrock_region
      POWERTOOLS_SERVICE_NAME = "ansible-ai-reviewer"
      LOG_LEVEL               = "INFO"
    }
  }

  tags = var.tags
}

# CloudWatch Logsグループ（保持期間30日）
resource "aws_cloudwatch_log_group" "reviewer" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 30

  tags = var.tags
}
