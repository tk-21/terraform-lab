output "alb_dns_name" {
  description = "ALB DNS name (access this in browser)"
  value       = aws_lb.this.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.this.arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.this.name
}

output "log_group_name" {
  description = "CloudWatch Logs group"
  value       = aws_cloudwatch_log_group.ecs.name
}
