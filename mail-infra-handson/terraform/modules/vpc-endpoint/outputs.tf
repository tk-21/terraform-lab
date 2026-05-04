output "endpoint_id" {
  description = "VPC Endpoint ID"
  value       = aws_vpc_endpoint.ses_smtp.id
}

output "endpoint_dns_names" {
  description = "VPC EndpointのDNS名一覧（private_dns_enabled=trueの場合は通常利用不要）"
  value       = aws_vpc_endpoint.ses_smtp.dns_entry[*].dns_name
}

output "security_group_id" {
  description = "VPC EndpointにアタッチしたSecurity Group ID"
  value       = aws_security_group.ses_endpoint.id
}
