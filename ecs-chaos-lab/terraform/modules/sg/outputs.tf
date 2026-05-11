output "alb_sg_id" {
  description = "ALB セキュリティグループ ID"
  value       = aws_security_group.alb.id
}

output "ecs_task_sg_id" {
  description = "ECS Task セキュリティグループ ID"
  value       = aws_security_group.ecs_task.id
}
