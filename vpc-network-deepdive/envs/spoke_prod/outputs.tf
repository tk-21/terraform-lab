
output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr" { value = module.vpc.vpc_cidr }
output "subnet_ids" { value = module.vpc.subnet_ids }
output "route_table_ids" { value = module.vpc.route_table_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
