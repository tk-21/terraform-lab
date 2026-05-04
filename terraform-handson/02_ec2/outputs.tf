output "instance_id" {
  description = "EC2 インスタンス ID"
  value       = aws_instance.web.id
}

output "public_ip" {
  description = "Elastic IP アドレス（固定パブリック IP）"
  value       = aws_eip.web.public_ip
}

output "web_url" {
  description = "Apache 確認 URL（ブラウザでアクセスして動作確認）"
  value       = "http://${aws_eip.web.public_ip}"
}

output "security_group_id" {
  description = "Web SG ID（03_rds で RDS へのアクセス許可設定に使用）"
  value       = aws_security_group.web.id
}

output "ami_id" {
  description = "使用した AMI ID（Amazon Linux 2023）"
  value       = data.aws_ami.amazon_linux_2023.id
}
