locals {
  name_prefix = "${var.project}-${var.environment}"
}

# -----------------------------------------------------------------
# Dead Letter Queue（DLQ）
# リトライ上限を超えたメッセージの隔離先
# -----------------------------------------------------------------
resource "aws_sqs_queue" "input_dlq" {
  name                       = "${local.name_prefix}-input-dlq"
  message_retention_seconds  = 1209600 # 14 days（DLQ は長めに保持して調査可能にする）
  receive_wait_time_seconds  = 0
  sqs_managed_sse_enabled    = true

  tags = {
    Name = "${local.name_prefix}-input-dlq"
  }
}

# -----------------------------------------------------------------
# Input Queue（メインのジョブ受付キュー）
# API Gateway から SQS へ直接統合で受け取る
# -----------------------------------------------------------------
resource "aws_sqs_queue" "input" {
  name                       = "${local.name_prefix}-input"
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20 # Long Polling（コスト削減、レイテンシ改善）
  sqs_managed_sse_enabled    = true

  # DLQ 設定: max_receive_count 回配信されたら DLQ へ移動
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.input_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = {
    Name = "${local.name_prefix}-input"
  }
}

# DLQ からメインキューへ手動で戻す（再試行時）を許可するポリシー
resource "aws_sqs_queue_policy" "input_dlq" {
  queue_url = aws_sqs_queue.input_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRedriveFromSourceQueue"
        Effect = "Allow"
        Principal = {
          Service = "sqs.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.input_dlq.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_sqs_queue.input.arn
          }
        }
      }
    ]
  })
}

# API Gateway が SQS に直接 SendMessage するためのリソースポリシー
resource "aws_sqs_queue_policy" "input" {
  queue_url = aws_sqs_queue.input.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAPIGateway"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.input.arn
      }
    ]
  })
}

# -----------------------------------------------------------------
# SNS: ジョブ完了 / 失敗の通知トピック
# Step Functions の SNS SDK 統合で Publish される
# -----------------------------------------------------------------
resource "aws_sns_topic" "notifications" {
  name = "${local.name_prefix}-notifications"

  tags = {
    Name = "${local.name_prefix}-notifications"
  }
}

# -----------------------------------------------------------------
# SNS: 運用アラート（DLQ 蓄積、停滞ジョブ検出）
# CloudWatch Alarm / Cleanup Lambda が Publish する
# -----------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = {
    Name = "${local.name_prefix}-alerts"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
