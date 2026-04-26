# drift-detector Lambda関数のデプロイ定義
# ソースコードはlambda/drift_detector/ディレクトリをZIP圧縮してデプロイする

locals {
  # ソースコードのハッシュ値でLambdaの更新を検知する
  source_dir  = "${path.module}/../../../lambda/drift_detector"
  output_path = "${path.module}/../../../lambda/drift_detector.zip"
}

# Lambdaデプロイ用ZIPアーカイブを作成する
data "archive_file" "drift_detector" {
  type        = "zip"
  source_dir  = local.source_dir
  output_path = local.output_path
}

resource "aws_lambda_function" "drift_detector" {
  function_name    = "drift-detective-detector"
  description      = "tfstateと実環境のCloudFormationドリフトを比較して差分を検知する"
  role             = var.lambda_role_arn
  handler          = "index.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 180
  memory_size      = 256
  filename         = data.archive_file.drift_detector.output_path
  source_code_hash = data.archive_file.drift_detector.output_base64sha256

  environment {
    variables = {
      MONITORED_TFSTATE_BUCKET = var.monitored_tfstate_bucket
      MONITORED_TFSTATE_KEY    = var.monitored_tfstate_key
      MONITORED_CFN_STACKS     = var.monitored_cfn_stacks
      POWERTOOLS_SERVICE_NAME  = "drift-detector"
      LOG_LEVEL                = "INFO"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = var.log_group_name
  }

  tags = var.tags
}

# 非同期呼び出し時のリトライ設定（最大2回リトライ）
resource "aws_lambda_function_event_invoke_config" "drift_detector" {
  function_name          = aws_lambda_function.drift_detector.function_name
  maximum_retry_attempts = 2
}
