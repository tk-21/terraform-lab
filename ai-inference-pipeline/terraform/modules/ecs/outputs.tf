output "cluster_arn" { value = aws_ecs_cluster.main.arn }
output "cluster_name" { value = aws_ecs_cluster.main.name }
output "task_definition_arn" { value = aws_ecs_task_definition.preprocessor.arn }
output "task_definition_family" { value = aws_ecs_task_definition.preprocessor.family }
output "ecs_security_group_id" { value = aws_security_group.ecs_task.id }
