output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDのリスト"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDのリスト"
  value       = module.vpc.private_subnet_ids
}

output "app_instance_ids" {
  description = "App EC2インスタンスIDのリスト"
  value       = module.ec2.app_instance_ids
}

output "app_private_ips" {
  description = "App EC2のプライベートIPリスト"
  value       = module.ec2.app_private_ips
}

output "bastion_instance_id" {
  description = "Bastion EC2のインスタンスID（SSM接続に使用）"
  value       = module.ec2.bastion_instance_id
}

output "bastion_public_ip" {
  description = "Bastion EC2のパブリックIP"
  value       = module.ec2.bastion_public_ip
}

output "alb_dns_name" {
  description = "ALBのDNS名（ブラウザアクセス用）"
  value       = module.alb.alb_dns_name
}

output "github_actions_role_arn" {
  value       = module.github_actions_oidc.github_actions_role_arn
  description = "GitHub ActionsワークフローのIAM Role ARN"
}

output "cloudwatch_dashboard_name" {
  description = "CloudWatchダッシュボード名"
  value       = module.cloudwatch.dashboard_name
}

output "cloudwatch_sns_topic_arn" {
  description = "アラート通知SNSトピックARN"
  value       = module.cloudwatch.sns_topic_arn
}

output "cloudwatch_ssm_parameter_name" {
  description = "CloudWatch Agent設定のSSMパラメータ名"
  value       = module.cloudwatch.ssm_parameter_name
}
