################################################################################
# VPCモジュール - 出力値定義
#
# 他モジュール（EKS, Addons）が参照するIDをすべて出力する。
# 出力を明示することでモジュール間の依存関係が明確になる。
################################################################################

output "vpc_id" {
  description = "VPCのID。EKSクラスター・セキュリティグループ作成時に使用"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPCのCIDRブロック。セキュリティグループのインバウンドルール設定時に使用"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDのリスト。ALB配置時に使用"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDのリスト。EKS Node Group・Pod配置時に使用"
  value       = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  description = "分離サブネットIDのリスト。RDS・ElastiCache配置時に使用"
  value       = aws_subnet.isolated[*].id
}

output "nat_gateway_ids" {
  description = "NAT GatewayのIDリスト。ルーティング確認やコスト分析時に使用"
  value       = aws_nat_gateway.this[*].id
}

output "internet_gateway_id" {
  description = "インターネットゲートウェイのID"
  value       = aws_internet_gateway.this.id
}

output "vpc_endpoint_security_group_id" {
  description = "VPC Endpoint用セキュリティグループのID。EKSノードのSGルール追加時に参照"
  value       = aws_security_group.vpc_endpoint.id
}

output "public_route_table_id" {
  description = "パブリックルートテーブルのID"
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "プライベートルートテーブルのIDリスト（AZごと）"
  value       = aws_route_table.private[*].id
}
