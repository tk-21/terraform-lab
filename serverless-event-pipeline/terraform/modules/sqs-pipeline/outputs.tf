# sqs-pipeline モジュールのアウトプット定義
# 呼び出し元（environments/dev）が IAM ポリシーや他モジュールで参照できるように公開する。

output "queue_arn" {
  description = "SQS メインキューの ARN。Lambda 実行ロールの ReceiveMessage 権限で参照する。"
  value       = aws_sqs_queue.main.arn
}

output "queue_url" {
  description = "SQS メインキューの URL。SQS API 呼び出し（SendMessage など）で参照する。"
  value       = aws_sqs_queue.main.url
}

output "dlq_arn" {
  description = "デッドレターキューの ARN。dlq-handler Lambda のイベントソースマッピングで参照する。"
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "デッドレターキューの URL。手動での DLQ メッセージ確認・再処理で参照する。"
  value       = aws_sqs_queue.dlq.url
}

output "raw_input_bucket_name" {
  description = "S3 raw input バケット名。Lambda 環境変数 RAW_INPUT_BUCKET に設定して S3 GetObject で参照する。"
  value       = aws_s3_bucket.raw_input.bucket
}

output "raw_input_bucket_arn" {
  description = "S3 raw input バケットの ARN。Lambda 実行ロールの S3 GetObject IAM ポリシーで参照する。"
  value       = aws_s3_bucket.raw_input.arn
}
