output "name_prefix" {
  description = "リソース命名プレフィックス"
  value       = local.name_prefix
}

output "aws_region" {
  description = "デプロイリージョン"
  value       = var.aws_region
}

# Networking outputs
output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト"
  value       = module.networking.private_subnet_ids
}

output "sg_msk_id" {
  description = "MSK用セキュリティグループID"
  value       = module.networking.sg_msk_id
}

output "sg_lambda_id" {
  description = "Lambda Producer用セキュリティグループID"
  value       = module.networking.sg_lambda_id
}

output "sg_flink_id" {
  description = "Flink用セキュリティグループID"
  value       = module.networking.sg_flink_id
}

# S3 outputs
output "output_bucket_id" {
  description = "Flinkイベント出力バケット名"
  value       = module.s3.output_bucket_id
}

output "flink_app_bucket_id" {
  description = "FlinkアプリJAR格納バケット名"
  value       = module.s3.flink_app_bucket_id
}

# IAM outputs
output "flink_role_arn" {
  description = "Flink実行ロールARN"
  value       = module.iam.flink_role_arn
}

output "producer_role_arn" {
  description = "Lambda Producer実行ロールARN"
  value       = module.iam.producer_role_arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDCロールARN"
  value       = module.iam.github_actions_role_arn
}

# MSK outputs
output "msk_bootstrap_brokers_sasl_iam" {
  description = "MSK Serverless IAM認証ブートストラップブローカー"
  value       = module.msk.msk_bootstrap_brokers_sasl_iam
}

# Flink outputs
output "flink_app_name" {
  description = "Managed Flink アプリケーション名"
  value       = module.flink.application_name
}

# VPC Lattice outputs
output "vpc_lattice_service_network_arn" {
  description = "VPC Lattice Service Network ARN"
  value       = module.vpc_lattice.service_network_arn
}

# Glue outputs
output "glue_database_name" {
  description = "Glue Data Catalog データベース名"
  value       = module.glue.glue_database_name
}

output "athena_workgroup_name" {
  description = "Athena ワークグループ名"
  value       = module.glue.athena_workgroup_name
}

# CloudWatch outputs
output "cloudwatch_dashboard_url" {
  description = "CloudWatch ダッシュボードURL"
  value       = module.observability.dashboard_url
}
