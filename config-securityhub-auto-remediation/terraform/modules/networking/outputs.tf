output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト (Lambda配置先)"
  value       = aws_subnet.private[*].id
}

output "lambda_security_group_id" {
  description = "Lambda用セキュリティグループID"
  value       = aws_security_group.lambda.id
}

output "vpc_endpoint_security_group_id" {
  description = "VPC Endpoint用セキュリティグループID"
  value       = aws_security_group.vpc_endpoint.id
}

output "private_route_table_id" {
  description = "プライベートサブネット用ルートテーブルID"
  value       = aws_route_table.private.id
}
