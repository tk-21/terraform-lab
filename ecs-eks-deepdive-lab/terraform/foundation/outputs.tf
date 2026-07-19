# Phase 2 (ECS) / Phase 3 (EKS) のTerraformが参照する主要な値
# terraform output -json で取得して使用する

output "region" {
  description = "AWSリージョン"
  value       = var.region
}

output "project" {
  description = "プロジェクト名プレフィックス"
  value       = var.project
}
