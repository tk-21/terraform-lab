output "instance_id" {
  description = "EC2インスタンスID（Terratest / GitHub Actions確認用）"
  value       = module.compute.instance_id
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト（Terratestでサブネット検証に使用）"
  value       = module.vpc.private_subnet_ids
}

output "ec2_security_group_id" {
  description = "EC2セキュリティグループID（Terratestでインバウンドルール検証に使用）"
  value       = module.compute.security_group_id
}
