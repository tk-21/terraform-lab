# Phase 1で出力可能な値（後フェーズで追記）
output "name_prefix" {
  description = "Common name prefix for resources"
  value       = local.name_prefix
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

# Networking
output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.networking.private_subnet_ids
}

# S3
output "raw_bucket_id" {
  description = "Raw S3 bucket name"
  value       = module.s3.raw_bucket_id
}

output "processed_bucket_id" {
  description = "Processed S3 bucket name"
  value       = module.s3.processed_bucket_id
}

output "athena_results_bucket_id" {
  description = "Athena results S3 bucket name"
  value       = module.s3.athena_results_bucket_id
}

# IAM
output "firehose_role_arn" {
  description = "Firehose IAM role ARN"
  value       = module.iam.firehose_role_arn
}

output "lambda_receiver_role_arn" {
  description = "Lambda Receiver IAM role ARN"
  value       = module.iam.lambda_receiver_role_arn
}

output "lambda_generator_role_arn" {
  description = "Lambda Generator IAM role ARN"
  value       = module.iam.lambda_generator_role_arn
}

output "databrew_role_arn" {
  description = "DataBrew IAM role ARN"
  value       = module.iam.databrew_role_arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDC role ARN"
  value       = module.iam.github_actions_role_arn
}

# Firehose
output "firehose_delivery_stream_name" {
  description = "Kinesis Data Firehose delivery stream name"
  value       = module.firehose.delivery_stream_name
}

# Lambda
output "lambda_receiver_function_name" {
  description = "Lambda Receiver function name"
  value       = module.lambda_receiver.function_name
}

output "lambda_generator_function_name" {
  description = "Lambda Generator function name"
  value       = module.lambda_generator.function_name
}

# ALB
output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.alb_dns_name
}

# Global Accelerator
output "accelerator_dns_name" {
  description = "Global Accelerator DNS name"
  value       = module.global_accelerator.accelerator_dns_name
}

output "accelerator_ip_sets" {
  description = "Global Accelerator static IP addresses"
  value       = module.global_accelerator.accelerator_ip_sets
}

# Global Accelerator（追加）
output "accelerator_arn" {
  description = "Global Accelerator ARN"
  value       = module.global_accelerator.accelerator_arn
}

output "accelerator_static_ips" {
  description = "Global Accelerator static IP addresses (flat list)"
  value       = flatten([for s in module.global_accelerator.accelerator_ip_sets : s.ip_addresses])
}

# ALB（追加）
output "alb_arn" {
  description = "ALB ARN"
  value       = module.alb.alb_arn
}

# Firehose（追加）
output "firehose_stream_arn" {
  description = "Kinesis Data Firehose delivery stream ARN"
  value       = module.firehose.delivery_stream_arn
}

# S3（追加: より分かりやすいエイリアス）
output "raw_bucket_name" {
  description = "Raw S3 bucket name"
  value       = module.s3.raw_bucket_id
}

output "processed_bucket_name" {
  description = "Processed S3 bucket name"
  value       = module.s3.processed_bucket_id
}

output "athena_results_bucket_name" {
  description = "Athena results S3 bucket name"
  value       = module.s3.athena_results_bucket_id
}

# DataBrew
output "databrew_job_name" {
  description = "Glue DataBrew job name"
  value       = module.databrew.job_name
}

output "databrew_project_name" {
  description = "Glue DataBrew project name"
  value       = module.databrew.project_name
}

# Glue / Athena
output "glue_database_name" {
  description = "Glue Data Catalog database name"
  value       = module.glue.database_name
}

output "athena_workgroup_name" {
  description = "Athena workgroup name"
  value       = module.glue.athena_workgroup_name
}

# Observability
output "cloudwatch_dashboard_name" {
  description = "CloudWatch Dashboard name"
  value       = module.observability.dashboard_name
}

# 便利URL（マネコンへの直リンク）
output "cloudwatch_dashboard_url" {
  description = "CloudWatch Dashboard URL"
  value       = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=${local.name_prefix}-dashboard"
}

output "athena_workgroup_url" {
  description = "Athena Workgroup URL"
  value       = "https://ap-northeast-1.console.aws.amazon.com/athena/home?region=ap-northeast-1#/workgroups"
}
