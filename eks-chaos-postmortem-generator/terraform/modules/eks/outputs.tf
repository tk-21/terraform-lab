# =============================================================================
# EKSモジュール アウトプット定義
# =============================================================================

output "cluster_name" {
  description = "EKSクラスター名（kubectlやFIS実験テンプレートで使用）"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKSクラスターAPIエンドポイント（kubeconfigの生成に使用）"
  value       = aws_eks_cluster.main.endpoint
}

output "oidc_provider_url" {
  description = "OIDC プロバイダーURL（IRSAのfederated principalに使用）"
  value       = aws_iam_openid_connect_provider.eks.url
}

output "cluster_certificate_authority_data" {
  description = "クラスターCA証明書データ（kubeconfigの生成に使用）"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}
