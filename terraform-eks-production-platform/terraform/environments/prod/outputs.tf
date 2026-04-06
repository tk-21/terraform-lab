################################################################################
# prod環境 - 出力値定義
#
# terraform apply後に確認すべき重要なリソース情報を出力する。
# 機密情報は sensitive=true を設定してターミナル出力を抑制する。
################################################################################

# VPC関連
output "vpc_id" {
  description = "VPCのID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト"
  value       = module.vpc.private_subnet_ids
}

# EKS関連
output "cluster_name" {
  description = "EKSクラスター名。kubectl設定コマンドに使用"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS APIサーバーのエンドポイント"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "kubeconfigを更新するコマンド（コピーして実行してください）"
  value       = "aws eks update-kubeconfig --region ap-northeast-1 --name ${module.eks.cluster_name}"
}

# Observability関連
output "amp_workspace_endpoint" {
  description = "AMPのPrometheusエンドポイントURL"
  value       = module.observability.amp_prometheus_endpoint
}

output "grafana_workspace_endpoint" {
  description = "GrafanaダッシュボードURL"
  value       = "https://${module.observability.grafana_workspace_endpoint}"
}

# ArgoCD関連
output "argocd_admin_secret_arn" {
  description = "ArgoCDのadminパスワードが格納されたSecrets ManagerのARN"
  value       = module.addons.argocd_admin_secret_arn
}

output "argocd_password_command" {
  description = "ArgoCDのadminパスワードを取得するコマンド"
  value       = "aws secretsmanager get-secret-value --secret-id ${module.addons.argocd_admin_secret_arn} --query SecretString --output text"
}
