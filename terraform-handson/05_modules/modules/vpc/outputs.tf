output "vpc_id" {
  description = "VPCのID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDのリスト"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDのリスト"
  value       = [for s in aws_subnet.private : s.id]
}

output "public_subnet_map" {
  description = "AZ名 → サブネットID のマップ (特定AZを指定したい場合に使用)"
  value       = { for az, s in aws_subnet.public : az => s.id }
}
