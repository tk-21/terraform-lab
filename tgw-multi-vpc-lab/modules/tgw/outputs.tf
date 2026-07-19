output "tgw_id" {
  description = "Transit GatewayのID"
  value       = aws_ec2_transit_gateway.this.id
}

output "tgw_arn" {
  description = "Transit GatewayのARN"
  value       = aws_ec2_transit_gateway.this.arn
}

output "spoke_route_table_id" {
  description = "Spoke用ルートテーブルID（Spoke-A/BのAssociationおよびHub伝播に使用）"
  value       = aws_ec2_transit_gateway_route_table.spoke.id
}

output "hub_route_table_id" {
  description = "Hub/Inspection用ルートテーブルID（HubのAssociationおよびSpoke伝播に使用）"
  value       = aws_ec2_transit_gateway_route_table.hub.id
}
