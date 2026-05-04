output "instance_id" {
  description = "EC2インスタンスID"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Elastic IPアドレス"
  value       = aws_eip.this.public_ip
}

output "security_group_id" {
  description = "セキュリティグループID (他モジュールからSGルール追加に使用)"
  value       = aws_security_group.this.id
}
