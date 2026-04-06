################################################################################
# Observabilityモジュール - 出力値定義
################################################################################

output "amp_workspace_id" {
  description = "Amazon Managed PrometheusワークスペースのID"
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "Amazon Managed PrometheusワークスペースのARN"
  value       = aws_prometheus_workspace.this.arn
}

output "amp_prometheus_endpoint" {
  description = "AMPのPrometheusエンドポイントURL。Remote Write設定に使用"
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

output "grafana_workspace_id" {
  description = "Amazon Managed GrafanaワークスペースのID"
  value       = aws_grafana_workspace.this.id
}

output "grafana_workspace_endpoint" {
  description = "GrafanaダッシュボードのURLエンドポイント"
  value       = aws_grafana_workspace.this.endpoint
}

output "prometheus_remote_write_irsa_role_arn" {
  description = "Prometheus Remote Write用IRSAロールのARN"
  value       = aws_iam_role.prometheus_remote_write.arn
}
