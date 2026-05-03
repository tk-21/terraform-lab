# =============================================================
# outputs.tf — 動作確認に必要な情報を出力
# =============================================================

output "master_public_ip" {
  value = aws_instance.master.public_ip
}

output "slave_public_ips" {
  value = aws_instance.slave[*].public_ip
}

output "slave_private_ips" {
  description = "lsyncd 設定の転送先（プライベート IP）"
  value       = aws_instance.slave[*].private_ip
}

output "ssh_command_master" {
  value = "ssh -i ansible/keys/ec2_key.pem ec2-user@${aws_instance.master.public_ip}"
}

output "verify_commands" {
  description = "動作確認コマンド"
  value = {
    create_on_master = "ssh -i ansible/keys/ec2_key.pem ec2-user@${aws_instance.master.public_ip} 'echo hello-lsyncd | sudo tee /var/www/html/test.html'"
    check_slave_1    = "curl http://${aws_instance.slave[0].public_ip}/test.html"
    check_slave_2    = "curl http://${aws_instance.slave[1].public_ip}/test.html"
  }
}
