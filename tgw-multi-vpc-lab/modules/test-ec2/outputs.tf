output "instance_id" {
  description = "EC2インスタンスID（SSM send-commandのターゲットに使用）"
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "EC2のプライベートIP（ping確認のターゲットに使用）"
  value       = aws_instance.this.private_ip
}
