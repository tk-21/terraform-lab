output "amp_workspace_id" {
  description = "AMPワークスペースID"
  value       = aws_prometheus_workspace.main.id
}

output "amp_workspace_arn" {
  description = "AMPワークスペースARN"
  value       = aws_prometheus_workspace.main.arn
}

output "amp_remote_write_url" {
  description = "ADOTコレクターのremote_write先URL"
  value       = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}

output "amp_query_endpoint" {
  description = "GrafanaのData Source設定に使うAMPクエリエンドポイント"
  value       = aws_prometheus_workspace.main.prometheus_endpoint
}

output "grafana_workspace_id" {
  description = "AMGワークスペースID"
  value       = aws_grafana_workspace.main.id
}

output "grafana_endpoint" {
  description = "GrafanaダッシュボードURL"
  value       = "https://${aws_grafana_workspace.main.endpoint}"
}

output "adot_role_arn" {
  description = "ADOTコレクターのIRSAロールARN（k8s/monitoring/adot-collector.yamlのアノテーションに使用）"
  value       = aws_iam_role.adot.arn
}
