output "target_private_ip" {
  value = aws_instance.target.private_ip
}

output "target_public_ip" {
  value = aws_instance.target.public_ip
}

output "zabbix_server_private_ip" {
  value = aws_instance.zabbix_server.private_ip
}

output "zabbix_server_public_ip" {
  value = aws_instance.zabbix_server.public_ip
}
