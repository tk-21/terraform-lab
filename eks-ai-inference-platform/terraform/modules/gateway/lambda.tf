# ────────────────────────────────────────────────
# Lambda デプロイパッケージ (archive_file)
# ────────────────────────────────────────────────

data "archive_file" "cost_alert_lambda" {
  type = "zip"
  # モジュールからの相対パス: terraform/modules/gateway/ → src/cost_lambda/
  source_file = "${path.module}/../../../src/cost_lambda/main.py"
  output_path = "${path.module}/../../../src/cost_lambda/cost_alert_lambda.zip"
}

# ────────────────────────────────────────────────
# DLQ: Lambda 処理失敗時のメッセージ保存
# ────────────────────────────────────────────────

resource "aws_sqs_queue" "lambda_dlq" {
  # コストアラート通知に失敗した場合のデッドレターキュー
  # 保持期間を 14 日にして調査の猶予を確保する
  name                      = "${local.name_prefix}-cost-alert-dlq"
  message_retention_seconds = 1209600 # 14日

  tags = local.common_tags
}

# ────────────────────────────────────────────────
# Lambda 関数: Chatwork コストアラート通知
# ────────────────────────────────────────────────

resource "aws_lambda_function" "cost_alert" {
  function_name = "${local.name_prefix}-cost-alert"
  description   = "推論コスト超過を Chatwork に通知する (CloudWatch Alarm → SNS → Lambda)"
  runtime       = "python3.12"
  # arm64 は x86_64 より約 20% 安価: コスト監視 Lambda 自体のコストも最小化する
  architectures = ["arm64"]
  handler       = "main.handler"
  role          = aws_iam_role.cost_alert_lambda.arn
  filename      = data.archive_file.cost_alert_lambda.output_path
  # ソースコード変更時のみデプロイを再実行させる
  source_code_hash = data.archive_file.cost_alert_lambda.output_base64sha256

  timeout     = 30
  memory_size = 128

  # Lambda Powertools レイヤー (arm64用): 構造化ログ・トレーシングを追加コードなしで有効化する
  layers = [
    "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:7"
  ]

  # アラームスパイク時に過剰な Chatwork 通知が連続しないよう同時実行を制限する
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "cost-alert-lambda"
      POWERTOOLS_LOG_LEVEL    = "INFO"
      AWS_LAMBDA_LOG_FORMAT   = "JSON"
    }
  }

  # X-Ray トレーシング: SSM 呼び出しや外部 HTTP 通信のレイテンシを可視化する
  tracing_config {
    mode = "Active"
  }

  tags = local.common_tags
}

# SNS が Lambda を呼び出せるようにするリソースベースポリシー
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_alert.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cost_alert.arn
}
