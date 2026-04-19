output "api_endpoint" {
  description = "API GatewayのエンドポイントURL（/reviewパス含む）"
  value       = "${aws_api_gateway_stage.reviewer.invoke_url}/review"
}

output "api_key_id" {
  description = "API KeyのID（ValueはAWSコンソールまたはSSMから取得）"
  value       = aws_api_gateway_api_key.reviewer.id
}
