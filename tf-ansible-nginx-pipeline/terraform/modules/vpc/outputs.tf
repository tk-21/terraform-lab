output "vpc_id" {
  description = "VPC ID（computeモジュールで使用）"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト（EC2配置用）"
  value       = [for s in aws_subnet.private : s.id]
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDリスト（ALB配置用）"
  value       = [for s in aws_subnet.public : s.id]
}

output "vpc_cidr" {
  description = "VPC CIDRブロック（セキュリティグループルール設定に使用）"
  value       = aws_vpc.this.cidr_block
}
