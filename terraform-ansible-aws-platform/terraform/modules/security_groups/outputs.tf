output "alb_sg_id" {
  description = "ALB Security GroupのID"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "App EC2 Security GroupのID"
  value       = aws_security_group.app.id
}

output "bastion_sg_id" {
  description = "Bastion EC2 Security GroupのID"
  value       = aws_security_group.bastion.id
}
