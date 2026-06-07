output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public Subnet ID リスト"
  value       = module.networking.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Private App Subnet ID リスト（ECS Fargate 配置用）"
  value       = module.networking.private_app_subnet_ids
}

output "private_db_subnet_ids" {
  description = "Private DB Subnet ID リスト（Aurora / RDS Proxy 配置用）"
  value       = module.networking.private_db_subnet_ids
}

output "vpc_endpoint_sg_id" {
  description = "VPC Endpoint 用セキュリティグループ ID"
  value       = module.networking.vpc_endpoint_sg_id
}

# Phase 2: Aurora Serverless v2
output "aurora_cluster_endpoint" {
  description = "Aurora Writer エンドポイント"
  value       = module.aurora.cluster_endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora Reader エンドポイント"
  value       = module.aurora.cluster_reader_endpoint
}

output "aurora_master_secret_arn" {
  description = "マスターユーザー認証情報の Secrets Manager ARN"
  value       = module.aurora.master_secret_arn
}

# Phase 3: RDS Proxy
output "proxy_endpoint" {
  description = "RDS Proxy Writer エンドポイント"
  value       = module.rds_proxy.proxy_endpoint
}

output "proxy_reader_endpoint" {
  description = "RDS Proxy Reader エンドポイント"
  value       = module.rds_proxy.proxy_reader_endpoint
}

output "app_rds_connect_policy_arn" {
  description = "ECS Task Role にアタッチする RDS Proxy 接続ポリシー ARN（Phase 5 で使用）"
  value       = module.rds_proxy.app_rds_connect_policy_arn
}

# Phase 5: ECS Fargate
output "alb_dns_name" {
  description = "ALB DNS 名（動作確認: http://<dns>/health）"
  value       = module.ecs_app.alb_dns_name
}

output "ecr_repo_url" {
  description = "ECR リポジトリ URL（docker buildx build --push 先）"
  value       = module.ecs_app.ecr_repo_url
}

output "ecs_cluster_name" {
  description = "ECS クラスター名"
  value       = module.ecs_app.ecs_cluster_name
}

output "ecs_service_name" {
  description = "ECS サービス名"
  value       = module.ecs_app.ecs_service_name
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDC ロール ARN（GitHub Secrets: AWS_ACCOUNT_ID と合わせて設定）"
  value       = module.ecs_app.github_actions_role_arn
}

# Phase 4: Secrets Manager ローテーション
output "app_secret_arn" {
  description = "appuser シークレット ARN（Phase 5 の ECS Task IAM ポリシーに使用）"
  value       = module.secrets.app_secret_arn
}
