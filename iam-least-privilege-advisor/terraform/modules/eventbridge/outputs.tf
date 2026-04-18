output "scheduler_arn" {
  description = "EventBridge Scheduler の ARN"
  value       = aws_scheduler_schedule.weekly_scan.arn
}

output "scheduler_name" {
  description = "EventBridge Scheduler の名前"
  value       = aws_scheduler_schedule.weekly_scan.name
}

output "scheduler_role_arn" {
  description = "EventBridge Scheduler 用 IAM ロールの ARN"
  value       = aws_iam_role.scheduler.arn
}
