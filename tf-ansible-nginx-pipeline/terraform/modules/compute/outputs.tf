output "instance_id" {
  description = "EC2インスタンスID（Ansible Dynamic Inventoryで自動取得されるが、GitHub Actionsでの確認用）"
  value       = aws_instance.web.id
}

output "private_ip" {
  description = "プライベートIP（Ansible接続先確認用）"
  value       = aws_instance.web.private_ip
}

output "security_group_id" {
  description = "EC2セキュリティグループID（Terratestでインバウンドルール検証に使用）"
  value       = aws_security_group.ec2.id
}
