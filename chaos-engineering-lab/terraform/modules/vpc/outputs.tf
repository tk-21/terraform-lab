output "vpc_id" {
  description = "VPC の ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID のリスト（ALB 配置用）"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID のリスト（EC2/ASG 配置用）"
  value       = aws_subnet.private[*].id
}
