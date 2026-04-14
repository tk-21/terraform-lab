# dev 環境のアウトプット定義
# デプロイ後に確認・スクリプト利用・他モジュール参照で使用する値を公開する。

output "ingestor_function_name" {
  description = "ingestor Lambda 関数名。CloudWatch Logs グループ名（/aws/lambda/<name>）の構築や CLI 操作で使用する。"
  value       = module.ingestor.function_name
}

output "ingestor_function_arn" {
  description = "ingestor Lambda 関数 ARN。EventBridge ルールや他 AWS サービスとの統合で参照する。"
  value       = module.ingestor.function_arn
}

output "ingestor_alias_arn" {
  description = "ingestor Lambda live エイリアス ARN。ESM・カナリアデプロイの設定で参照する。"
  value       = module.ingestor.alias_arn
}

output "raw_input_bucket_name" {
  description = "S3 raw input バケット名。テストデータのアップロード（aws s3 cp）で使用する。"
  value       = module.sqs_pipeline_ingest.raw_input_bucket_name
}

output "ingest_queue_url" {
  description = "ingest SQS キュー URL。メッセージの手動送信・監視で参照する。"
  value       = module.sqs_pipeline_ingest.queue_url
}

output "ingest_queue_arn" {
  description = "ingest SQS キュー ARN。IAM ポリシーや他リソースの接続設定で参照する。"
  value       = module.sqs_pipeline_ingest.queue_arn
}

output "ingest_dlq_url" {
  description = "ingest DLQ URL。障害調査時の DLQ メッセージ確認・再処理で使用する。"
  value       = module.sqs_pipeline_ingest.dlq_url
}

output "alerts_topic_arn" {
  description = "アラート用 SNS トピック ARN。CloudWatch アラームや他モジュールのアラーム接続で参照する。"
  value       = aws_sns_topic.alerts.arn
}

# ── DynamoDB テーブル ─────────────────────────────────────────────

output "events_table_name" {
  description = "events DynamoDB テーブル名。テストデータの投入やクエリで使用する。"
  value       = module.dynamodb.events_table_name
}

output "events_stream_arn" {
  description = "events DynamoDB Streams ARN。aggregator ESM の設定確認で参照する。"
  value       = module.dynamodb.events_stream_arn
}

output "aggregations_table_name" {
  description = "aggregations DynamoDB テーブル名。集計結果の確認（aws dynamodb scan）で使用する。"
  value       = module.dynamodb.aggregations_table_name
}

# ── aggregator Lambda ────────────────────────────────────────────

output "aggregator_function_name" {
  description = "aggregator Lambda 関数名。CloudWatch Logs やメトリクスの確認で使用する。"
  value       = module.aggregator.function_name
}

output "aggregator_function_arn" {
  description = "aggregator Lambda 関数 ARN。"
  value       = module.aggregator.function_arn
}

output "aggregator_log_group_name" {
  description = "aggregator Lambda の CloudWatch Logs グループ名。障害調査時のログ確認で使用する。"
  value       = module.aggregator.log_group_name
}
