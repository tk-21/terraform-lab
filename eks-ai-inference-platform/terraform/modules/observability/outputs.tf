output "amp_workspace_id" {
  description = "AMPワークスペースID (OTEL CollectorのConfigMapで使用)"
  value       = aws_prometheus_workspace.main.id
}

output "amp_workspace_arn" {
  description = "AMPワークスペースARN"
  value       = aws_prometheus_workspace.main.arn
}

output "amp_remote_write_url" {
  description = "AMP remote_write エンドポイントURL (OTEL Collector設定に使用)"
  value       = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}

output "amp_query_url" {
  description = "AMP クエリエンドポイントURL (AMG データソース設定に使用)"
  value       = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/query"
}

output "otel_collector_irsa_arn" {
  description = "OTEL Collector IRSAロールARN (k8s/otel/serviceaccount.yaml のアノテーションに設定)"
  value       = aws_iam_role.otel_collector.arn
}

output "amg_workspace_id" {
  description = "AMGワークスペースID"
  value       = aws_grafana_workspace.main.id
}

output "amg_workspace_url" {
  description = "AMG ダッシュボードURL"
  value       = "https://${aws_grafana_workspace.main.endpoint}"
}
