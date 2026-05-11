output "fis_role_arn" {
  description = "FIS 実行ロール ARN (fis モジュールで使用)"
  value       = aws_iam_role.fis_execution.arn
}

output "fis_role_name" {
  description = "FIS 実行ロール名"
  value       = aws_iam_role.fis_execution.name
}

output "task_execution_role_arn" {
  description = "ECS Task 実行ロール ARN (ecs モジュールで使用)"
  value       = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  description = "ECS Task ロール ARN (ecs モジュールで使用)"
  value       = aws_iam_role.task.arn
}
