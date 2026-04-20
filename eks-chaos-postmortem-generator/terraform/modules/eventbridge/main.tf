# =============================================================================
# EventBridgeモジュール - FIS実験完了イベント検知
# FIS実験のcompleted / failed / stopped 状態変化を検知し、
# Orchestrator Lambda（fis-event-handler）を起動する。
# 配信失敗時はSQS DLQにイベントを保全してデータロストを防ぐ。
# =============================================================================

# ------------------------------------------------------------
# Dead Letter Queue (SQS)
# EventBridgeからLambdaへの配信が失敗した場合にイベントを保全する。
# Lambda再試行後も失敗した場合のフォールバックとして機能する。
# ------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name = "${var.project}-fis-events-dlq-${var.environment}"

  # 失敗イベントを14日間保持してデバッグと手動リドライブを可能にする
  message_retention_seconds = 1209600

  tags = var.tags
}

# EventBridgeがDLQにメッセージを送信することを許可するSQSポリシー
resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgeSendMessage"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.dlq.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.fis_state_change.arn
          }
        }
      }
    ]
  })
}

# ------------------------------------------------------------
# EventBridgeルール: FIS実験状態変化の検知
# completed/failed/stopped の全終了状態を対象とし、
# 失敗した実験もポストモーテム分析対象として扱う。
# ------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "fis_state_change" {
  name        = "${var.project}-fis-state-change-${var.environment}"
  description = "FIS実験のcompleted/failed/stopped状態変化を検知してOrchestratorLambdaを起動"

  event_pattern = jsonencode({
    source      = ["aws.fis"]
    detail-type = ["FIS Experiment State Change"]
    detail = {
      state = {
        # 全終了状態をキャプチャ: 失敗分析もポストモーテムの対象とする
        status = ["completed", "failed", "stopped"]
      }
    }
  })

  tags = var.tags
}

# ------------------------------------------------------------
# EventBridgeターゲット: Orchestrator Lambda
# FISイベントをLambdaに配信する。配信失敗時はDLQに退避する。
# ------------------------------------------------------------
resource "aws_cloudwatch_event_target" "fis_to_lambda" {
  rule      = aws_cloudwatch_event_rule.fis_state_change.name
  target_id = "FISToOrchestratorLambda"
  arn       = var.lambda_function_arn

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

# EventBridgeからLambdaを呼び出す権限を付与する
resource "aws_lambda_permission" "eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvokeFISEventHandler"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.fis_state_change.arn
}
