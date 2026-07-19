# Dead Letter Queue: 3回失敗したメッセージを14日間保持して調査できるようにする
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project}-job-dlq"
  message_retention_seconds = 1209600 # 14日: 障害調査のための十分な保持期間
  sqs_managed_sse_enabled   = true

  tags = { Name = "${var.project}-job-dlq" }
}

resource "aws_sqs_queue" "job" {
  name = "${var.project}-job-queue"

  # ワーカーの最大処理時間に合わせる
  # これより短いと処理中に可視化され二重処理が起きる
  visibility_timeout_seconds = 300

  message_retention_seconds = 86400 # 1日

  # ロングポーリングでポーリング回数を減らしコスト削減
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    # 3回受信しても処理完了しないメッセージはDLQへ移動
    maxReceiveCount = 3
  })

  tags = { Name = "${var.project}-job-queue" }
}

output "sqs_queue_url" {
  value = aws_sqs_queue.job.url
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.job.arn
}

output "sqs_dlq_url" {
  value = aws_sqs_queue.dlq.url
}
