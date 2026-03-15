output "aws_region" {
  value = var.aws_region
}

output "ecr_repo_url" {
  value = module.ecr.repo_url
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = module.ecs.service_name
}

output "ecs_task_family" {
  value = module.ecs.task_family
}

output "ecs_task_definition_arn" {
  value = module.ecs.task_definition_arn
}

output "ecs_migrate_task_definition_arn" {
  value = module.ecs.migrate_task_definition_arn
}

output "alb_dns_name" {
  value = module.alb.dns_name
}

output "db_endpoint" {
  value = module.rds.endpoint
}

output "db_port" {
  value = module.rds.port
}

output "db_name" {
  value = module.rds.db_name
}
