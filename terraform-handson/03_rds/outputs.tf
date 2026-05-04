output "db_endpoint" {
  description = "RDS エンドポイント（EC2 から mysql -h <endpoint> で接続）"
  value       = aws_db_instance.main.endpoint
}

output "db_host" {
  description = "RDS ホスト名（ポート番号なし）"
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "RDS ポート番号"
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "データベース名"
  value       = aws_db_instance.main.db_name
}

output "db_username" {
  description = "DB ユーザー名"
  value       = aws_db_instance.main.username
}
