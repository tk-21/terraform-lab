output "alb_dns_name" {
  description = "AtlantisのALB DNS名 (GitHub Webhook設定に使用)"
  value       = aws_lb.atlantis.dns_name
}

output "ecs_cluster_name" {
  description = "ECSクラスター名"
  value       = aws_ecs_cluster.atlantis.name
}

output "ecs_service_name" {
  description = "ECSサービス名"
  value       = aws_ecs_service.atlantis.name
}

output "task_role_arn" {
  description = "AtlantisのTask RoleのARN (デバッグ・権限確認用)"
  value       = aws_iam_role.task_role.arn
}

output "atlantis_url" {
  description = "Atlantis WebUI/Webhook受信URL"
  value       = "http://${aws_lb.atlantis.dns_name}"
}

output "webhook_url" {
  description = "GitHub Webhookに設定するURL"
  value       = "http://${aws_lb.atlantis.dns_name}/events"
}

output "log_group_name" {
  description = "AtlantisのCloudWatch Logsグループ名"
  value       = aws_cloudwatch_log_group.atlantis.name
}
