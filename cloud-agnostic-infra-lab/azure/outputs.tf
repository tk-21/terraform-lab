output "lb_public_ip" {
  description = "LBのパブリックIPアドレス（疎通確認に使用）"
  value       = azurerm_public_ip.lb.ip_address
}

output "resource_group_name" {
  description = "リソースグループ名（Azure固有概念の記録）"
  value       = azurerm_resource_group.main.name
}
