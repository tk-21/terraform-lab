output "cluster_name" {
  description = "EKSクラスタ名"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS APIエンドポイントURL"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKSクラスタのCA証明書データ（base64エンコード）"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "oidc_issuer_url" {
  description = "EKS OIDCプロバイダーURL（IRSAに使用）"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
