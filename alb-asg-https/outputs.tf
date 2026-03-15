output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "public_route_table_id" {
  value = module.network.public_route_table_id
}

# output "web_instance_ids" {
#   value = { for k, v in aws_instance.web : k => v.id }
# }

output "asg_name" {
  value = module.asg_web.asg_name
}

output "launch_template_id" {
  value = module.asg_web.launch_template_id
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "target_group_arn" {
  value = module.alb.target_group_arn
}

output "web_sg_id" {
  value = module.alb.web_sg_id
}
