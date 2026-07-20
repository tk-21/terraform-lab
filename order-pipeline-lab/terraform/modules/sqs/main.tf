# DLQ (Dead Letter Queue) — 先に作成する
resource "aws_sqs_queue" "orders_dlq" {
  name = "${var.project}-orders-dlq"

  # なぜ: DLQ は調査・再処理の猶予として 7日間保持
  message_retention_seconds = 604800

  tags = merge(var.common_tags, { Name = "${var.project}-orders-dlq" })
}

# メインの注文キュー
resource "aws_sqs_queue" "orders" {
  name = "${var.project}-orders-queue"

  # なぜ: Step Functions の最大実行時間 (1年) より長くする必要はないが、
  #       1回の処理で最大 5分かかる想定で 300秒に設定
  #       visibility_timeout < 処理時間 だとメッセージが再配信されてしまう
  visibility_timeout_seconds = 300

  # なぜ: 処理失敗したメッセージを調査できるよう 1日保持
  message_retention_seconds = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    # なぜ: 3回受信して失敗したメッセージは DLQ へ移動
    #       1回目: 一時的な障害かもしれない
    #       2回目: まだリトライする価値がある
    #       3回目: 諦めて DLQ で原因調査
    maxReceiveCount = 3
  })

  tags = merge(var.common_tags, { Name = "${var.project}-orders-queue" })
}

# CloudWatch Alarm: DLQ メッセージ数監視
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.project}-dlq-messages-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0 # なぜ: DLQ に 1件でも届いたらアラート

  dimensions = {
    QueueName = aws_sqs_queue.orders_dlq.name
  }

  alarm_description = "DLQ にメッセージが届いています。注文処理の失敗を調査してください。"

  tags = var.common_tags
}
