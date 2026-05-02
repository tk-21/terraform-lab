output "cluster_endpoint" {
  description = "Aurora cluster writer endpoint (書き込み用)"
  value       = aws_rds_cluster.main.endpoint
}

output "reader_endpoint" {
  description = "Aurora cluster reader endpoint (読み取り用 — ライター負荷軽減)"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "cluster_identifier" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.main.cluster_identifier
}

output "port" {
  description = "Aurora cluster port (3306)"
  value       = aws_rds_cluster.main.port
}
