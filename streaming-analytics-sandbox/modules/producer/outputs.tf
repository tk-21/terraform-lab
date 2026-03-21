output "api_endpoint" {
  description = "API Gateway invoke URL (base)"
  value       = aws_api_gateway_stage.this.invoke_url
}

output "events_endpoint" {
  description = "POST /events endpoint URL"
  value       = "${aws_api_gateway_stage.this.invoke_url}/events"
}

output "api_key_id" {
  description = "API Key ID (retrieve value: aws apigateway get-api-key --api-key <id> --include-value)"
  value       = aws_api_gateway_api_key.this.id
}

output "rest_api_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.this.id
}
