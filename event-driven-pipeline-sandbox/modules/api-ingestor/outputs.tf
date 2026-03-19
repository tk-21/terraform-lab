output "api_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.main.id
}

output "api_endpoint" {
  description = "API Gateway invoke URL"
  value       = aws_api_gateway_stage.main.invoke_url
}

output "jobs_endpoint" {
  description = "POST /jobs endpoint"
  value       = "${aws_api_gateway_stage.main.invoke_url}/jobs"
}

output "api_key_id" {
  description = "API Gateway API Key ID"
  value       = aws_api_gateway_api_key.client.id
}

output "api_key_value" {
  description = "API Gateway API Key value (use as X-API-Key header)"
  value       = aws_api_gateway_api_key.client.value
  sensitive   = true
}
