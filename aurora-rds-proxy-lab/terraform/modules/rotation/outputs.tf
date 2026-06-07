output "app_secret_arn" {
  description = "アプリ用 DB ユーザーシークレット ARN（Phase 5 の ECS Task IAM ポリシーに使用）"
  value       = aws_secretsmanager_secret.app_db.arn
}

output "rotator_sg_id" {
  description = "ローテーション Lambda セキュリティグループ ID"
  value       = aws_security_group.rotator.id
}
