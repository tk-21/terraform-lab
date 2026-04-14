# kinesis-pipeline モジュールのアウトプット定義
# 呼び出し元（dev/main.tf など）が Kinesis ストリームや DLQ の ARN を参照できるように公開する。

output "stream_arn" {
  description = "Kinesis Data Streams の ARN。IAM ポリシーや他モジュールでストリームを参照する際に使用する。"
  value       = aws_kinesis_stream.events.arn
}

output "stream_name" {
  description = "Kinesis Data Streams の名前。CloudWatch メトリクスのディメンションや AWS CLI での参照に使用する。"
  value       = aws_kinesis_stream.events.name
}

output "dlq_arn" {
  description = "ESM 失敗送信先 SQS DLQ の ARN。dlq-handler Lambda の ESM やアラーム設定で参照する。"
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_url" {
  description = "ESM 失敗送信先 SQS DLQ の URL。AWS SDK での DLQ 操作（ReceiveMessage など）に使用する。"
  value       = aws_sqs_queue.dlq.id
}

output "kms_key_arn" {
  description = "Kinesis ストリーム暗号化に使用する KMS キーの ARN。他サービスからの暗号化データ送信時に参照する。"
  value       = aws_kms_key.kinesis.arn
}

output "kms_key_id" {
  description = "Kinesis ストリーム暗号化に使用する KMS キー ID。"
  value       = aws_kms_key.kinesis.key_id
}

output "event_source_mapping_uuid" {
  description = "Lambda ESM（イベントソースマッピング）の UUID。ESM の有効化・無効化操作に使用する。"
  value       = aws_lambda_event_source_mapping.kinesis_to_lambda.uuid
}
