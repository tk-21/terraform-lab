output "vpc_id" {
  description = "VPC ID (EKSモジュール・Karpenterモジュールが参照する)"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト (EKSノードグループ・Karpenterが使用)"
  value       = [for s in aws_subnet.private : s.id]
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDリスト (ALB配置用)"
  value       = [for s in aws_subnet.public : s.id]
}

output "vpc_cidr" {
  description = "VPC CIDRブロック (セキュリティグループのIngress設定に使用)"
  value       = aws_vpc.main.vpc_cidr_block
}

output "vpc_endpoint_sg_id" {
  description = "VPC Endpoint用セキュリティグループID"
  value       = aws_security_group.vpc_endpoint.id
}
