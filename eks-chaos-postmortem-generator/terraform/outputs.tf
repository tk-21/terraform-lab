# =============================================================================
# Terraformアウトプット定義 - EKS Chaos Postmortem Generator
# =============================================================================

# EKSクラスター情報の出力
output "eks_cluster_name" {
  description = "EKSクラスター名（kubectlコマンドや各種設定に使用）"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKSクラスターAPIエンドポイント（kubeconfigの生成に使用）"
  value       = module.eks.cluster_endpoint
}

output "eks_oidc_provider_url" {
  description = "EKS OIDCプロバイダーURL（IRSA設定のfederated principalに使用）"
  value       = module.eks.oidc_provider_url
}

# VPC情報の出力
output "vpc_id" {
  description = "VPC ID（他リソースとの統合時に使用）"
  value       = module.vpc.vpc_id
}
