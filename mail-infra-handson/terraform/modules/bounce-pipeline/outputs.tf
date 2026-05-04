output "bounce_sns_topic_arn" {
  description = "バウンス通知SNSトピックのARN。ses-configモジュールのイベント転送先として使用する"
  value       = aws_sns_topic.bounce.arn
}

output "complaint_sns_topic_arn" {
  description = "苦情通知SNSトピックのARN。ses-configモジュールのイベント転送先として使用する"
  value       = aws_sns_topic.complaint.arn
}

output "suppression_table_name" {
  description = "サプレッションリストDynamoDBテーブル名。inbound-pipeline・suppression-syncモジュールへ渡す"
  value       = aws_dynamodb_table.suppression_list.name
}

output "suppression_table_arn" {
  description = "サプレッションリストDynamoDBテーブルのARN。IAMポリシー構築に使用する"
  value       = aws_dynamodb_table.suppression_list.arn
}

output "bounce_handler_function_name" {
  description = "bounce_handler Lambda関数名。monitoringモジュールのダッシュボードで参照する"
  value       = aws_lambda_function.bounce_handler.function_name
}

output "bounce_handler_function_arn" {
  description = "bounce_handler Lambda関数のARN"
  value       = aws_lambda_function.bounce_handler.arn
}
