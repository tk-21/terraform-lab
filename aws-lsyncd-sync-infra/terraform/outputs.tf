# =============================================================
# outputs.tf — 動作確認に必要な情報を出力
# =============================================================

output "master_instance_id" {
  description = "SSM Session Manager での接続に使用"
  value       = aws_instance.master.id
}

output "slave_instance_ids" {
  description = "SSM Session Manager での接続に使用"
  value       = aws_instance.slave[*].id
}

output "slave_public_ips" {
  value = aws_instance.slave[*].public_ip
}

output "slave_private_ips" {
  description = "lsyncd 設定の転送先（プライベート IP）"
  value       = aws_instance.slave[*].private_ip
}

output "ssm_command_master" {
  description = "master への SSM セッション接続コマンド"
  value       = "aws ssm start-session --target ${aws_instance.master.id} --region ap-northeast-1"
}

output "verify_commands" {
  description = "動作確認コマンド"
  value = {
    create_on_master = "aws ssm start-session --target ${aws_instance.master.id} --region ap-northeast-1"
    check_slave_1    = "curl http://${aws_instance.slave[0].public_ip}/test.html"
    check_slave_2    = "curl http://${aws_instance.slave[1].public_ip}/test.html"
  }
}
