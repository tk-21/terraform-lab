################################################################################
# EKSモジュール - 出力値定義
################################################################################

output "cluster_id" {
  description = "EKSクラスターのID"
  value       = aws_eks_cluster.this.id
}

output "cluster_name" {
  description = "EKSクラスター名。kubectl, helmコマンドで使用"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKSクラスターのARN"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "EKS APIサーバーのエンドポイントURL。kubeconfigに使用"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKSクラスターのCA証明書データ。kubeconfigに使用"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "EKS Kubernetesバージョン"
  value       = aws_eks_cluster.this.version
}

output "oidc_provider_arn" {
  description = "OIDC ProviderのARN。IRSAのTrust Policy設定に使用"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC ProviderのURL（プロトコルなし）。IRSAのConditionキーに使用"
  value       = local.oidc_provider_url
}

output "node_group_role_arn" {
  description = "Managed Node Group用IAMロールのARN。aws-auth ConfigMapに登録"
  value       = aws_iam_role.node_group.arn
}

output "karpenter_node_role_arn" {
  description = "Karpenterが起動するノード用IAMロールのARN"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_node_instance_profile_name" {
  description = "KarpenterノードのInstance Profile名。EC2NodeClassで参照"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "karpenter_irsa_role_arn" {
  description = "Karpenter用IRSAロールのARN。Helm valuesで設定"
  value       = aws_iam_role.karpenter.arn
}

output "karpenter_sqs_queue_url" {
  description = "Karpenterスポット中断処理用SQSキューのURL"
  value       = aws_sqs_queue.karpenter_interruption.url
}

output "karpenter_sqs_queue_name" {
  description = "Karpenterスポット中断処理用SQSキュー名"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "lbc_irsa_role_arn" {
  description = "AWS Load Balancer Controller用IRSAロールのARN"
  value       = aws_iam_role.lbc.arn
}

output "argocd_irsa_role_arn" {
  description = "ArgoCD用IRSAロールのARN"
  value       = aws_iam_role.argocd.arn
}

output "app_irsa_role_arn" {
  description = "サンプルアプリ用IRSAロールのARN"
  value       = aws_iam_role.app.arn
}

output "node_security_group_id" {
  description = "EKSノード用セキュリティグループのID"
  value       = aws_security_group.node.id
}

output "cluster_security_group_id" {
  description = "EKSクラスター用セキュリティグループのID"
  value       = aws_security_group.cluster.id
}
