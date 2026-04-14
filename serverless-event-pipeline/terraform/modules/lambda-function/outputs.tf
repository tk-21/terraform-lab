# lambda-function モジュールのアウトプット定義
# 呼び出し元モジュール（kinesis-pipeline / sqs-pipeline など）が
# Lambda の ARN・ロール ARN などを参照できるように公開する。

output "function_arn" {
  description = "Lambda 関数の ARN。イベントソースマッピングや IAM ポリシーで参照する。"
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "Lambda 関数名。CloudWatch Logs グループ名の構築やデプロイスクリプトで参照する。"
  value       = aws_lambda_function.this.function_name
}

output "invoke_arn" {
  description = "Lambda の呼び出し ARN。API Gateway の統合設定で参照する。"
  value       = aws_lambda_function.this.invoke_arn
}

output "role_arn" {
  description = "Lambda 実行ロールの ARN。追加のポリシーアタッチや信頼関係の設定で参照する。"
  value       = aws_iam_role.lambda.arn
}

output "role_name" {
  description = "Lambda 実行ロール名。aws_iam_role_policy_attachment でポリシーを追加する際に参照する。"
  value       = aws_iam_role.lambda.name
}

output "alias_arn" {
  description = "live エイリアスの ARN。ESM（イベントソースマッピング）の function_name に指定することで、カナリアデプロイ時のトラフィック制御をエイリアスレベルで行える。"
  value       = aws_lambda_alias.live.arn
}

output "log_group_name" {
  description = "CloudWatch Logs グループ名。observability モジュールでメトリクスフィルターを設定する際に参照する。"
  value       = aws_cloudwatch_log_group.lambda.name
}
