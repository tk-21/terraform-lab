output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト（EKS ノード配置用）"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID リスト（ALB 配置用）"
  value       = module.vpc.public_subnets
}

output "intra_subnet_ids" {
  description = "イントラサブネット ID リスト（EKS Control Plane ENI 配置用）"
  value       = module.vpc.intra_subnets
}
