
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "subnet_ids" {
  value = module.vpc.subnet_ids
}

output "route_table_ids" {
  value = module.vpc.route_table_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "privatelink_service_name" {
  description = "Spoke側にEndpointを作成するときに使用するService Name"
  value       = module.privatelink_service.endpoint_service_name
}

output "privatelink_service_instance_id" {
  description = "Hub NginxのEC2インスタンスID（Session Manager接続確認用）"
  value       = module.privatelink_service.service_instance_id
}
