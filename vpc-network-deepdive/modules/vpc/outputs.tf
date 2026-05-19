
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDRブロック（Peeringルート設定で使用）"
  value       = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "サブネットIDマップ: { 'private-1a' = 'subnet-xxx' }"
  value       = { for k, v in aws_subnet.this : k => v.id }
}

output "route_table_ids" {
  description = "ルートテーブルIDマップ: { 'private' = 'rtb-xxx' }"
  value       = { for k, v in aws_route_table.this : k => v.id }
}

output "private_subnet_ids" {
  description = "privateサブネットIDのリスト（Endpointのsubnet_ids引数で使用）"
  value = [
    for k, v in aws_subnet.this : v.id
    if startswith(k, "private")
  ]
}
