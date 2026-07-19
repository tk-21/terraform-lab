output "vpc_id" {
  description = "VPCのID"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDのマップ（key=CIDR, value=subnet_id）"
  value       = { for cidr, subnet in aws_subnet.private : cidr => subnet.id }
}

output "tgw_subnet_ids" {
  description = "TGW専用サブネットIDのマップ（key=CIDR, value=subnet_id）"
  value       = { for cidr, subnet in aws_subnet.tgw : cidr => subnet.id }
}

output "private_route_table_ids" {
  description = "プライベートサブネット用ルートテーブルIDのリスト"
  value       = [aws_route_table.private.id]
}

output "tgw_route_table_id" {
  description = "TGW専用サブネット用ルートテーブルID"
  value       = aws_route_table.tgw.id
}

output "vpc_cidr" {
  description = "VPC CIDRブロック（他モジュールでのセキュリティグループルール設定に使用）"
  value       = aws_vpc.this.cidr_block
}
