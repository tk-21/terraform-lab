output "cluster_name" {
  description = "ECS クラスター名 (fis モジュールで使用)"
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ECS クラスター ARN (fis モジュールで使用)"
  value       = aws_ecs_cluster.main.arn
}

output "service_name" {
  description = "ECS サービス名 (fis モジュールで使用)"
  value       = aws_ecs_service.main.name
}

output "service_arn" {
  description = "ECS サービス ARN"
  value       = aws_ecs_service.main.id
}

output "task_definition_arn" {
  description = "ECS Task Definition ARN"
  value       = aws_ecs_task_definition.main.arn
}

output "log_group_name" {
  description = "CloudWatch Logs グループ名"
  value       = aws_cloudwatch_log_group.ecs.name
}

output "stop_condition_alarm_task_kill_arn" {
  description = "FIS 停止条件アラーム ARN（シナリオ1: Task Kill 用）"
  value       = aws_cloudwatch_metric_alarm.running_task_count_low.arn
}

output "stop_condition_alarm_network_arn" {
  description = "FIS 停止条件アラーム ARN（シナリオ2: Network Disruption 用）"
  value       = aws_cloudwatch_metric_alarm.healthy_host_count_zero.arn
}
