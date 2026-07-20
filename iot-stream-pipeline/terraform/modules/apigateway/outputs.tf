output "api_endpoint" {
  description = "センサーデータ取得APIのベースURL"
  value       = "${aws_api_gateway_stage.v1.invoke_url}/sensors"
}

output "api_id" {
  value = aws_api_gateway_rest_api.sensors.id
}
