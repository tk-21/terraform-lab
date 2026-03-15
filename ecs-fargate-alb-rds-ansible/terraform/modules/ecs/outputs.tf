output "cluster_name" { value = aws_ecs_cluster.this.name }
output "service_name" { value = aws_ecs_service.this.name }
output "task_family"  { value = aws_ecs_task_definition.app.family }

output "task_definition_arn" {
  value = aws_ecs_task_definition.app.arn
}

output "migrate_task_definition_arn" {
  value = aws_ecs_task_definition.migrate.arn
}

output "service_security_group_id" {
  value = aws_security_group.service.id
}
