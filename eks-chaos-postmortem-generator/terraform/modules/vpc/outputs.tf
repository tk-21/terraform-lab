# =============================================================================
# VPCモジュール アウトプット定義
# =============================================================================

output "vpc_id" {
  description = "VPC ID（EKSクラスターやセキュリティグループの設定に使用）"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDリスト（ALB/NAT GW配置先）"
  value       = [aws_subnet.public_1a.id, aws_subnet.public_1c.id]
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト（EKSノード配置先）"
  value       = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]
}
