output "api_id" {
  description = "HTTP API ID"
  value       = aws_apigatewayv2_api.main.id
}

output "api_endpoint" {
  description = "HTTP API endpoint URL (invoke URL)"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "chat_endpoint" {
  description = "POST /chat endpoint URL"
  value       = "${aws_apigatewayv2_stage.default.invoke_url}/chat"
}

output "execution_arn" {
  description = "HTTP API execution ARN"
  value       = aws_apigatewayv2_api.main.execution_arn
}

output "waf_web_acl_arn" {
  description = "WAF WebACL ARN"
  value       = aws_wafv2_web_acl.main.arn
}

output "access_log_group" {
  description = "CloudWatch Log Group for API Gateway access logs"
  value       = aws_cloudwatch_log_group.access_logs.name
}
