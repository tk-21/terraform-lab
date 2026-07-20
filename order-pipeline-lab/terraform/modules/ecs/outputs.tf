output "ecr_repository_url" { value = aws_ecr_repository.payment_processor.repository_url }
output "ecs_cluster_arn" { value = aws_ecs_cluster.main.arn }
output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "task_definition_arn" { value = aws_ecs_task_definition.payment_processor.arn }
output "ecs_task_sg_id" { value = aws_security_group.ecs_task.id }
output "ecs_task_role_arn" { value = aws_iam_role.ecs_task.arn }
output "ecs_execution_role_arn" { value = aws_iam_role.ecs_execution.arn }
