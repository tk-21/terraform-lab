# =============================================================
# 出力値定義
# 【学習ポイント】
#   - outputs.tf に集約することで他のモジュール・Step から
#     `terraform output -raw <name>` で参照できる
#   - description で何に使う値かを明記する
# =============================================================

output "vpc_id" {
  description = "VPC ID（02_ec2 / 03_rds / 04_alb で使用）"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR ブロック"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID リスト（02_ec2 / 04_alb で使用）"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト（03_rds で使用）"
  value       = aws_subnet.private[*].id
}

output "igw_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "パブリック用ルートテーブル ID"
  value       = aws_route_table.public.id
}
