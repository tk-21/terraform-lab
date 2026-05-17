output "web_sg_id" {
  description = "Web 層 Security Group ID"
  value       = aws_security_group.web.id
}

output "app_sg_id" {
  description = "App 層 Security Group ID"
  value       = aws_security_group.app.id
}

output "ssm_sg_id" {
  description = "SSM Session Manager 用 Security Group ID"
  value       = aws_security_group.ssm.id
}
