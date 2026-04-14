# dynamodb モジュールのアウトプット定義

# ── events テーブル ───────────────────────────────────────────────

output "events_table_name" {
  description = "events テーブル名。Lambda 環境変数（EVENTS_TABLE_NAME）に渡す。"
  value       = aws_dynamodb_table.events.name
}

output "events_table_arn" {
  description = "events テーブル ARN。IAM ポリシーのリソース指定に使用する。"
  value       = aws_dynamodb_table.events.arn
}

output "events_stream_arn" {
  description = <<-EOT
    events テーブルの DynamoDB Streams ARN。
    aggregator Lambda の aws_lambda_event_source_mapping に指定する。
    stream_enabled = true のときのみ値を持つ。
  EOT
  value = aws_dynamodb_table.events.stream_arn
}

# ── aggregations テーブル ─────────────────────────────────────────

output "aggregations_table_name" {
  description = "aggregations テーブル名。aggregator Lambda 環境変数（AGGREGATIONS_TABLE_NAME）に渡す。"
  value       = aws_dynamodb_table.aggregations.name
}

output "aggregations_table_arn" {
  description = "aggregations テーブル ARN。aggregator Lambda の IAM ポリシーに使用する。"
  value       = aws_dynamodb_table.aggregations.arn
}
