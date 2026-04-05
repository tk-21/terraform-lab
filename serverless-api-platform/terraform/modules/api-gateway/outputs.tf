# terraform/modules/api-gateway/outputs.tf

output "api_endpoint" {
  description = <<-EOT
    API のベース URL。
    形式: https://{api_id}.execute-api.{region}.amazonaws.com/{stage}
    例:   https://abc123.execute-api.ap-northeast-1.amazonaws.com/dev
    TODO(STEP 10): カスタムドメイン設定後はそちらを使用すること。
  EOT
  value = aws_api_gateway_stage.this.invoke_url
}

output "execution_arn" {
  description = <<-EOT
    API Gateway の実行 ARN。
    aws_lambda_permission の source_arn 設定で使用する。
    形式: arn:aws:execute-api:{region}:{account_id}:{api_id}
  EOT
  value = aws_api_gateway_rest_api.this.execution_arn
}

output "rest_api_id" {
  description = "REST API の ID。モニタリング（CloudWatch アラーム）で使用する。"
  value       = aws_api_gateway_rest_api.this.id
}

output "stage_name" {
  description = "ステージ名（= var.environment）。カスタムドメイン設定で使用する。"
  value       = aws_api_gateway_stage.this.stage_name
}
