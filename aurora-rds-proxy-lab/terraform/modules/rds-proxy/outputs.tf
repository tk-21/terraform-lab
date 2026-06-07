output "proxy_endpoint" {
  description = "RDS Proxy Writer エンドポイント"
  value       = aws_db_proxy.main.endpoint
}

output "proxy_reader_endpoint" {
  description = "RDS Proxy Reader エンドポイント"
  value       = aws_db_proxy_endpoint.reader.endpoint
}

output "proxy_sg_id" {
  description = "RDS Proxy セキュリティグループ ID（ECS SG の Egress 設定に使用）"
  value       = aws_security_group.proxy.id
}

output "proxy_arn" {
  description = "RDS Proxy ARN"
  value       = aws_db_proxy.main.arn
}
