output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDリスト"
  value       = module.vpc.public_subnet_ids
}

output "public_subnet_map" {
  description = "AZ → サブネットID マップ"
  value       = module.vpc.public_subnet_map
}

output "ec2_public_ip" {
  description = "EC2のElastic IP"
  value       = module.ec2.public_ip
}

output "web_url" {
  description = "WebサーバーURL"
  value       = "http://${module.ec2.public_ip}"
}
