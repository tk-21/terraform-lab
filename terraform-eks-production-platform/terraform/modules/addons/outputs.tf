################################################################################
# Addonsモジュール - 出力値定義
################################################################################

output "argocd_admin_secret_arn" {
  description = "ArgoCDのadminパスワードが格納されたSecrets ManagerのARN"
  value       = aws_secretsmanager_secret.argocd_admin.arn
}

output "argocd_namespace" {
  description = "ArgoCDがデプロイされているNamespace"
  value       = helm_release.argocd.namespace
}

output "karpenter_namespace" {
  description = "KarpenterがデプロイされているNamespace"
  value       = helm_release.karpenter.namespace
}

output "lbc_namespace" {
  description = "AWS Load Balancer ControllerがデプロイされているNamespace"
  value       = helm_release.aws_load_balancer_controller.namespace
}
