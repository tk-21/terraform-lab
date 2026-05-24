output "lb_ip_address" {
  description = "LBのグローバルIPアドレス（疎通確認に使用）"
  value       = google_compute_global_forwarding_rule.nginx.ip_address
}

output "network_name" {
  description = "VPCネットワーク名（AWSのVPC IDに相当するが概念が異なる）"
  value       = google_compute_network.main.name
}
