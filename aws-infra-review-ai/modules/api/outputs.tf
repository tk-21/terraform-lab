output "api_endpoint" {
  description = "API Gateway エンドポイント URL（POST /reviews でレビュー投入）"
  value       = "${aws_api_gateway_stage.dev.invoke_url}/reviews"
}

output "api_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.main.id
}

output "session_handler_lambda_arn" {
  description = "セッションハンドラー Lambda ARN"
  value       = aws_lambda_function.session_handler.arn
}
