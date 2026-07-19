output "alb_dns_name" {
  description = "ALB の DNS 名"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ALB の ARN"
  value       = aws_lb.main.arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト"
  value       = [aws_subnet.private_1a.id, aws_subnet.private_1c.id]
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID リスト"
  value       = [aws_subnet.public_1a.id, aws_subnet.public_1c.id]
}

output "ecs_cluster_arn" {
  description = "ECS クラスターの ARN"
  value       = aws_ecs_cluster.main.arn
}

output "alb_security_group_id" {
  description = "ALB セキュリティグループ ID"
  value       = aws_security_group.alb.id
}

output "acm_certificate_arn_use1" {
  description = "CloudFront 用 ACM 証明書 ARN (us-east-1)"
  value       = aws_acm_certificate_validation.cloudfront.certificate_arn
}
