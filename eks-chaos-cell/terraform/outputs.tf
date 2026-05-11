output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "vpc_id" { value = module.vpc.vpc_id }
output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ap-northeast-1 --name ${module.eks.cluster_name}"
}
output "alb_controller_role_arn" {
  description = "ALB Controller IRSAロールARN（alb-controller-sa.yamlのアノテーションに使用）"
  value       = aws_iam_role.alb_controller.arn
}

output "amp_workspace_id" {
  description = "AMPワークスペースID"
  value       = module.observability.amp_workspace_id
}

output "amp_remote_write_url" {
  description = "ADOTコレクターのremote_write先URL"
  value       = module.observability.amp_remote_write_url
}

output "amp_query_endpoint" {
  description = "GrafanaのData Source設定に使うAMPクエリエンドポイント"
  value       = module.observability.amp_query_endpoint
}

output "grafana_endpoint" {
  description = "GrafanaダッシュボードURL（AWS SSOでログイン）"
  value       = module.observability.grafana_endpoint
}

output "adot_role_arn" {
  description = "ADOTコレクターのIRSAロールARN（setup_observability.shで使用）"
  value       = module.observability.adot_role_arn
}
