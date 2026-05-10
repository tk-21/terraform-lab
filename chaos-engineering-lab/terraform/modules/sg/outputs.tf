output "alb_sg_id" {
  description = "ALB 用セキュリティグループの ID"
  value       = aws_security_group.alb.id
}

output "ec2_sg_id" {
  description = "EC2 用セキュリティグループの ID"
  value       = aws_security_group.ec2.id
}
