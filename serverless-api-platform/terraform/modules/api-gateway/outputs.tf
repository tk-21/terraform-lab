# terraform/modules/api-gateway/outputs.tf

output "rest_api_id" {
  description = "REST API の ID。モニタリング設定で使用する。"
  value       = aws_api_gateway_rest_api.this.id
}

output "invoke_url" {
  description = "API のエンドポイント URL。例: https://xxx.execute-api.ap-northeast-1.amazonaws.com/dev"
  value       = aws_api_gateway_stage.this.invoke_url
}

output "execution_arn" {
  description = "API Gateway の実行 ARN。Lambda の許可設定で使用する。"
  value       = aws_api_gateway_rest_api.this.execution_arn
}
