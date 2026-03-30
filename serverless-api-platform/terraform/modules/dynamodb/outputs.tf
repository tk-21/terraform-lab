# terraform/modules/dynamodb/outputs.tf

output "table_name" {
  description = "DynamoDB テーブル名。Lambda の環境変数として渡す。"
  value       = aws_dynamodb_table.items.name
}

output "table_arn" {
  description = "DynamoDB テーブル ARN。IAM ポリシーで参照する。"
  value       = aws_dynamodb_table.items.arn
}

output "stream_arn" {
  description = "DynamoDB Streams の ARN。stream-processor Lambda のイベントソースとして使用する。"
  value       = aws_dynamodb_table.items.stream_arn
}

output "dax_endpoint" {
  description = "DAX クラスターエンドポイント。enable_dax = false の場合は null。"
  value       = var.enable_dax ? aws_dax_cluster.this[0].cluster_address : null
}
