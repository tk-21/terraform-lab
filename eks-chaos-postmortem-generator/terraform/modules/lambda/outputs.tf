# =============================================================================
# Lambdaモジュール アウトプット定義
# =============================================================================

output "fis_event_handler_function_arn" {
  description = "fis-event-handler Lambda関数のARN（EventBridgeターゲット設定に使用）"
  value       = aws_lambda_function.fis_event_handler.arn
}

output "fis_event_handler_function_name" {
  description = "fis-event-handler Lambda関数名（EventBridgeのLambda権限設定に使用）"
  value       = aws_lambda_function.fis_event_handler.function_name
}

output "dynamodb_table_name" {
  description = "冪等性チェック用DynamoDBテーブル名（Lambda環境変数に渡す）"
  value       = aws_dynamodb_table.experiments.name
}

output "dynamodb_table_arn" {
  description = "冪等性チェック用DynamoDBテーブルのARN（IAMポリシーに使用）"
  value       = aws_dynamodb_table.experiments.arn
}

output "data_collector_function_arn" {
  description = "data-collector Lambda関数のARN（Step FunctionsのCollectDataステートに設定）"
  value       = aws_lambda_function.data_collector.arn
}

output "bedrock_analyzer_function_arn" {
  description = "bedrock-analyzer Lambda関数のARN（Step FunctionsのAnalyzeWithBedrockステートに設定）"
  value       = aws_lambda_function.bedrock_analyzer.arn
}

output "report_formatter_function_arn" {
  description = "report-formatter Lambda関数のARN（Step FunctionsのFormatReportステートに設定）"
  value       = aws_lambda_function.report_formatter.arn
}

output "notifier_function_arn" {
  description = "notifier Lambda関数のARN（Step FunctionsのNotify/ErrorNotifyステートに設定）"
  value       = aws_lambda_function.notifier.arn
}
