# bedrock-analyzer Lambda関数のデプロイ定義
# Bedrock呼び出しに時間がかかるためタイムアウト300秒・メモリ512MBで設定

locals {
  source_dir  = "${path.module}/../../../lambda/bedrock_analyzer"
  output_path = "${path.module}/../../../lambda/bedrock_analyzer.zip"
}

# Lambdaデプロイ用ZIPアーカイブを作成する
data "archive_file" "bedrock_analyzer" {
  type        = "zip"
  source_dir  = local.source_dir
  output_path = local.output_path
}

resource "aws_lambda_function" "bedrock_analyzer" {
  function_name = "drift-detective-analyzer"
  description   = "ドリフト情報をBedrock Claude Sonnetで分析し修復HCLを生成する"
  role          = var.lambda_role_arn
  handler       = "index.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  # Bedrock呼び出しに時間がかかるため300秒に設定
  timeout          = 300
  memory_size      = 512
  filename         = data.archive_file.bedrock_analyzer.output_path
  source_code_hash = data.archive_file.bedrock_analyzer.output_base64sha256

  environment {
    variables = {
      REPORTS_BUCKET          = var.reports_bucket
      BEDROCK_REGION          = var.bedrock_region
      POWERTOOLS_SERVICE_NAME = "bedrock-analyzer"
      LOG_LEVEL               = "INFO"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = var.log_group_name
  }

  tags = var.tags
}

# 非同期呼び出し時のリトライ設定（最大2回リトライ）
resource "aws_lambda_function_event_invoke_config" "bedrock_analyzer" {
  function_name          = aws_lambda_function.bedrock_analyzer.function_name
  maximum_retry_attempts = 2
}
