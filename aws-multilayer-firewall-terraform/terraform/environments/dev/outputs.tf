output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public サブネット ID マップ"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private サブネット ID マップ"
  value       = module.vpc.private_subnet_ids
}

output "firewall_subnet_ids" {
  description = "Firewall サブネット ID マップ (Phase 2 で使用)"
  value       = module.vpc.firewall_subnet_ids
}

output "web_sg_id" {
  description = "Web 層 Security Group ID"
  value       = module.security_group.web_sg_id
}

output "app_sg_id" {
  description = "App 層 Security Group ID"
  value       = module.security_group.app_sg_id
}

output "ssm_sg_id" {
  description = "SSM Session Manager 用 Security Group ID"
  value       = module.security_group.ssm_sg_id
}

output "ec2_instance_id" {
  description = "検証用 EC2 インスタンス ID (Session Manager で接続する際に使用)"
  value       = module.ec2_ssm.instance_id
}

output "ec2_private_ip" {
  description = "EC2 プライベート IP"
  value       = module.ec2_ssm.instance_private_ip
}

output "flow_log_group_name" {
  description = "VPC Flow Logs の CloudWatch Log Group 名"
  value       = module.vpc.flow_log_group_name
}

output "alb_dns_name" {
  description = "ALB の DNS 名（動作確認用）"
  value       = module.alb.alb_dns_name
}

output "waf_web_acl_arn" {
  description = "WAF WebACL ARN"
  value       = module.waf.web_acl_arn
}

output "waf_log_group" {
  description = "WAF ブロックログの CloudWatch Log Group 名"
  value       = module.waf.waf_log_group
}
