# terraform/modules/lambda-function/main.tf
#
# Lambda 関数の共通モジュール。
# 全ての Lambda 関数はこのモジュールを使用してデプロイする。
# 命名規則: sap-<env>-<操作>-<リソース>

locals {
  # Lambda デプロイパッケージの出力先
  zip_output_path = "${path.root}/dist/${var.function_name}.zip"
}

# Lambda デプロイパッケージ（zip）の生成
# source_dir のファイルを zip に圧縮する。
# ファイルの変更を検知して自動で再デプロイする。
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = local.zip_output_path
}

# Lambda 関数
# arm64 アーキテクチャで x86_64 より約20% コスト削減。
resource "aws_lambda_function" "this" {
  function_name = var.function_name
  description   = var.description
  role          = var.execution_role_arn

  # デプロイパッケージ
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = var.handler
  runtime          = var.runtime
  architectures    = var.architectures

  # タイムアウト設定
  # API Gateway 統合の場合は 25s（API GW 上限29s より短く）
  # 非同期処理の場合はより長い値を設定可能
  timeout     = var.timeout
  memory_size = var.memory_size

  environment {
    variables = var.environment_variables
  }

  # CloudWatch Logs への構造化ログ出力設定
  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  # X-Ray トレーシングの有効化
  # Lambda Powertools の @tracer.capture_lambda_handler と連携する
  tracing_config {
    mode = "Active"
  }
}

# CloudWatch Logs グループ
# Lambda の実行ログを保存する。保持期間を設定してコストを管理。
resource "aws_cloudwatch_log_group" "this" {
  # 命名規則: /aws/lambda/<function_name>
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

# DynamoDB Streams のイベントソースマッピング（stream-processor のみ）
# event_source_arn が指定された場合のみ作成する
resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
  count = var.event_source_arn != null ? 1 : 0

  event_source_arn  = var.event_source_arn
  function_name     = aws_lambda_function.this.arn
  starting_position = "LATEST"

  # バッチサイズを小さく設定して、監査ログの遅延を最小化する
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5

  # 部分的なバッチ失敗のレポートを有効化
  # 失敗したレコードのみリトライし、成功済みレコードを再処理しない
  function_response_types = ["ReportBatchItemFailures"]
}
