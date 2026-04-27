output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster for load testing"
  value       = aws_ecs_cluster.load_test.arn
}

output "task_definition_arn" {
  description = "ARN of the k6 ECS task definition"
  value       = aws_ecs_task_definition.k6.arn
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for k6 scripts and results"
  value       = aws_s3_bucket.k6.bucket
}

output "task_execution_role_arn" {
  description = "ARN of the ECS task execution IAM role"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "task_role_arn" {
  description = "ARN of the ECS task IAM role"
  value       = aws_iam_role.ecs_task.arn
}
