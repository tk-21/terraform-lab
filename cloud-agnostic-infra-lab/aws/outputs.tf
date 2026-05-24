output "alb_dns_name" {
  description = "ALBのDNS名（疎通確認に使用）"
  value       = aws_lb.main.dns_name
}

output "vpc_id" {
  description = "VPC ID（他クラウドとの概念比較メモ用）"
  value       = aws_vpc.main.id
}
