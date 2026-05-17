output "firewall_arn" {
  description = "Network Firewall の ARN"
  value       = aws_networkfirewall_firewall.main.arn
}

output "firewall_endpoint_id" {
  description = "Firewall Endpoint ID（1a）— ルートテーブルの vpc_endpoint_id に使用"
  value       = local.firewall_endpoint_id
}

output "nfw_alert_log_group" {
  description = "アラートログの CloudWatch Log Group 名"
  value       = aws_cloudwatch_log_group.nfw_alert.name
}

output "nfw_flow_log_group" {
  description = "フローログの CloudWatch Log Group 名"
  value       = aws_cloudwatch_log_group.nfw_flow.name
}

output "firewall_policy_arn" {
  description = "Firewall Policy の ARN"
  value       = aws_networkfirewall_firewall_policy.main.arn
}
