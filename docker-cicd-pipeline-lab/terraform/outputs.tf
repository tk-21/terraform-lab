output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID リスト"
  value       = module.networking.public_subnet_ids
}

output "ecr_repository_url" {
  description = "ECR リポジトリ URL"
  value       = module.ecr.repository_url
}

output "alb_dns_name" {
  description = "ALB の DNS 名 (アクセス確認用)"
  value       = module.alb.alb_dns_name
}

output "ecs_cluster_name" {
  description = "ECS クラスター名"
  value       = module.ecs.cluster_name
}

output "codepipeline_name" {
  description = "CodePipeline パイプライン名"
  value       = module.codepipeline.pipeline_name
}

output "artifact_bucket_id" {
  description = "アーティファクト S3 バケット ID"
  value       = aws_s3_bucket.artifacts.id
}

output "observability_dashboard_url" {
  description = "CloudWatch ダッシュボード URL"
  value       = module.observability.dashboard_url
}
