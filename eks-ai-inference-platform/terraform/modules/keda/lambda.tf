# ────────────────────────────────────────────────
# Lambda デプロイパッケージ
# ────────────────────────────────────────────────

data "archive_file" "scale_notify_lambda" {
  type = "zip"
  # モジュールからの相対パス: terraform/modules/keda/ → src/scale_notify_lambda/
  source_file = "${path.module}/../../../src/scale_notify_lambda/main.py"
  output_path = "${path.module}/../../../src/scale_notify_lambda/scale_notify_lambda.zip"
}

# ────────────────────────────────────────────────
# DLQ: Lambda処理失敗時のメッセージ保存
# ────────────────────────────────────────────────

resource "aws_sqs_queue" "scale_notify_dlq" {
  # EC2スケールイベント通知の失敗メッセージを保存する
  # 14日間保持してインシデント調査の猶予を確保する
  name                      = "${local.name_prefix}-scale-notify-dlq"
  message_retention_seconds = 1209600 # 14日

  tags = local.common_tags
}

# ────────────────────────────────────────────────
# Lambda 関数: GPU Spotスケールイベント Chatwork通知
# ────────────────────────────────────────────────

resource "aws_lambda_function" "scale_notify" {
  function_name = "${local.name_prefix}-scale-notify"
  description   = "GPU Spot ノードの起動/終了を Chatwork に通知する (EventBridge → Lambda)"
  runtime       = "python3.12"
  # arm64: x86_64より約20%安価でスケール通知のような軽量処理に最適
  architectures    = ["arm64"]
  handler          = "main.handler"
  role             = aws_iam_role.scale_notify_lambda.arn
  filename         = data.archive_file.scale_notify_lambda.output_path
  source_code_hash = data.archive_file.scale_notify_lambda.output_base64sha256

  timeout     = 30
  memory_size = 128

  # EC2スケールイベントは短時間に複数発生することがあるため同時実行を制限する
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  dead_letter_config {
    target_arn = aws_sqs_queue.scale_notify_dlq.arn
  }

  # Lambda Powertools: 構造化ログとX-Rayトレーシングを有効化する
  layers = [
    "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:7"
  ]

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "scale-notify-lambda"
      POWERTOOLS_LOG_LEVEL    = "INFO"
      AWS_LAMBDA_LOG_FORMAT   = "JSON"
    }
  }

  tracing_config {
    # X-Rayでec2 DescribeInstances / SSM / Chatwork HTTP呼び出しのレイテンシを可視化する
    mode = "Active"
  }

  tags = local.common_tags
}

# EventBridgeがLambdaを呼び出せるようにするリソースベースポリシー
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scale_notify.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.gpu_node_events.arn
}

# ────────────────────────────────────────────────
# CloudWatch Log Group: Lambdaログ保持期間管理
# ────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "scale_notify_lambda" {
  # Lambda関数名に対応したロググループを事前作成して保持期間を明示管理する
  name              = "/aws/lambda/${aws_lambda_function.scale_notify.function_name}"
  retention_in_days = 30

  tags = local.common_tags
}
