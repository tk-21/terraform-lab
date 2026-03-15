output "alb_dns_name" {
  value = module.alb.dns_name
}

output "db_endpoint" {
  value = module.rds.endpoint
}
