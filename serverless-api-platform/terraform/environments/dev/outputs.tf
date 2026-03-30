# terraform/environments/dev/outputs.tf
#
# dev 環境の出力値。
# CI/CD パイプラインや動作確認スクリプトから参照する。

output "api_endpoint" {
  description = "API Gateway のエンドポイント URL。curl や Postman でテストに使用する。"
  value       = module.api_gateway.invoke_url
}

output "dynamodb_table_name" {
  description = "DynamoDB テーブル名。AWS CLI でのデバッグに使用する。"
  value       = module.dynamodb.table_name
}

output "lambda_function_names" {
  description = "デプロイされた Lambda 関数名の一覧。"
  value = {
    list_items       = module.lambda_list_items.function_name
    get_item         = module.lambda_get_item.function_name
    create_item      = module.lambda_create_item.function_name
    update_item      = module.lambda_update_item.function_name
    delete_item      = module.lambda_delete_item.function_name
    stream_processor = module.lambda_stream_processor.function_name
  }
}

output "audit_bucket_name" {
  description = "DynamoDB Streams の監査ログを保存する S3 バケット名。"
  value       = module.storage.audit_bucket_name
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch ダッシュボードの URL。"
  value       = module.monitoring.dashboard_url
}
