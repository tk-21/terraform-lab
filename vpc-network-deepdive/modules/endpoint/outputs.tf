output "gateway_endpoint_ids" {
  description = "Gateway Endpoint IDマップ: { 's3' = 'vpce-xxx' }"
  value       = { for k, v in aws_vpc_endpoint.gateway : k => v.id }
}

output "interface_endpoint_ids" {
  description = "Interface Endpoint IDマップ: { 'ssm' = 'vpce-xxx' }"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "endpoint_security_group_id" {
  description = "Interface Endpoint用SG ID（EC2のegressルール参照用）"
  value       = aws_security_group.endpoint.id
}
