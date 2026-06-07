output "alb_dns_name" {
  description = "ALB DNS 名（動作確認用 URL の基点）"
  value       = aws_lb.app.dns_name
}

output "ecr_repo_url" {
  description = "ECR リポジトリ URL（docker push 先）"
  value       = aws_ecr_repository.app.repository_url
}

output "app_sg_id" {
  description = "ECS App セキュリティグループ ID"
  value       = aws_security_group.app.id
}

output "ecs_cluster_name" {
  description = "ECS クラスター名"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS サービス名"
  value       = aws_ecs_service.app.name
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDC ロール ARN（CI/CD 設定用）"
  value       = aws_iam_role.github_actions.arn
}
