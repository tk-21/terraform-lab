
output "peering_connection_id" {
  description = "VPC Peering Connection ID"
  value       = aws_vpc_peering_connection.this.id
}

output "peering_status" {
  description = "Peeringのステータス（active であることを確認）"
  value       = aws_vpc_peering_connection.this.accept_status
}
