output "cluster_name" {
  description = "EKSクラスタ名 (Karpenterモジュール・IAMモジュールが参照する)"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS APIサーバーのエンドポイント"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca" {
  description = "クラスタCA証明書 (kubeconfigで使用)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_oidc_issuer" {
  description = "OIDCプロバイダーのIssuer URL (IRSAロール作成時に参照する)"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "OIDCプロバイダーのARN (IRSAの信頼ポリシーで参照する)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_role_arn" {
  description = "EKSノード用IAMロールARN (Karpenter NodeClassで指定する)"
  value       = aws_iam_role.node.arn
}
