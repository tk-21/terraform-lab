output "cluster_id" {
  description = "Aurora クラスター識別子"
  value       = aws_rds_cluster.aurora.id
}

output "cluster_endpoint" {
  description = "Writer エンドポイント（書き込み用）"
  value       = aws_rds_cluster.aurora.endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader エンドポイント（読み取り用）"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "aurora_sg_id" {
  description = "Aurora セキュリティグループ ID（RDS Proxy SG のイングレス設定に使用）"
  value       = aws_security_group.aurora.id
}

output "master_secret_arn" {
  description = "マスターユーザー認証情報の Secrets Manager ARN（RDS Proxy 設定に使用）"
  value       = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
}

output "db_name" {
  description = "初期データベース名"
  value       = aws_rds_cluster.aurora.database_name
}

output "db_master_username" {
  description = "マスターユーザー名"
  value       = aws_rds_cluster.aurora.master_username
}

output "cluster_resource_id" {
  description = "Aurora クラスターリソース ID（IAM 認証ポリシーの Resource ARN に使用）"
  value       = aws_rds_cluster.aurora.cluster_resource_id
}
