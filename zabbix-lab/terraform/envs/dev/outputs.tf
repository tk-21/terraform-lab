output "zabbix_url" {
  value = "http://${module.ec2.zabbix_server_public_ip}/zabbix"
}

output "target_private_ip" {
  value = module.ec2.target_private_ip
}

output "target_public_ip" {
  value = module.ec2.target_public_ip
}

output "zabbix_server_private_ip" {
  value = module.ec2.zabbix_server_private_ip
}

output "zabbix_server_public_ip" {
  value = module.ec2.zabbix_server_public_ip
}
