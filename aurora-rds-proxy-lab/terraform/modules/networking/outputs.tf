output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public Subnet ID リスト（ALB 配置用）"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Private App Subnet ID リスト（ECS Fargate 配置用）"
  value       = aws_subnet.private_app[*].id
}

output "private_db_subnet_ids" {
  description = "Private DB Subnet ID リスト（Aurora / RDS Proxy 配置用）"
  value       = aws_subnet.private_db[*].id
}

output "vpc_endpoint_sg_id" {
  description = "VPC Endpoint 用セキュリティグループ ID"
  value       = aws_security_group.vpc_endpoint.id
}

output "vpc_cidr" {
  description = "VPC CIDR ブロック（SG ルール参照用）"
  value       = aws_vpc.main.cidr_block
}

output "internet_gateway_id" {
  description = "Internet Gateway ID（ALB ルートテーブル参照用）"
  value       = aws_internet_gateway.main.id
}

output "private_app_route_table_id" {
  description = "Private App サブネットのルートテーブル ID"
  value       = aws_route_table.private_app.id
}

output "private_db_route_table_id" {
  description = "Private DB サブネットのルートテーブル ID"
  value       = aws_route_table.private_db.id
}
