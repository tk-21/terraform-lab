output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDRブロック"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDリスト"
  value       = aws_subnet.public[*].id
}

output "sg_msk_id" {
  description = "MSK用セキュリティグループID"
  value       = aws_security_group.msk.id
}

output "sg_lambda_id" {
  description = "Lambda Producer用セキュリティグループID"
  value       = aws_security_group.lambda.id
}

output "sg_flink_id" {
  description = "Flink用セキュリティグループID"
  value       = aws_security_group.flink.id
}

output "sg_vpc_lattice_id" {
  description = "VPC Latticeエンドポイント用セキュリティグループID"
  value       = aws_security_group.vpc_lattice.id
}
