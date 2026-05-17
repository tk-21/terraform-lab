output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR ブロック"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public サブネット ID マップ (key: AZ suffix, e.g. '1a')"
  value       = { for k, v in aws_subnet.public : k => v.id }
}

output "public_subnet_cidrs" {
  description = "Public サブネット CIDR マップ (key: AZ suffix) — IGW Edge RT のルート生成に使用"
  value       = { for k, v in aws_subnet.public : k => v.cidr_block }
}

output "private_subnet_ids" {
  description = "Private サブネット ID マップ"
  value       = { for k, v in aws_subnet.private : k => v.id }
}

output "firewall_subnet_ids" {
  description = "Firewall サブネット ID マップ (Phase 2 で使用)"
  value       = { for k, v in aws_subnet.firewall : k => v.id }
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "Public ルートテーブル ID"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "Private ルートテーブル ID"
  value       = aws_route_table.private.id
}

output "flow_log_group_name" {
  description = "VPC Flow Logs の CloudWatch Log Group 名"
  value       = aws_cloudwatch_log_group.flow_log.name
}
