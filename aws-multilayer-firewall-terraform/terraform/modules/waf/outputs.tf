output "web_acl_arn" {
  description = "WAF WebACL の ARN"
  value       = aws_wafv2_web_acl.main.arn
}

output "web_acl_id" {
  description = "WAF WebACL の ID"
  value       = aws_wafv2_web_acl.main.id
}

output "waf_log_group" {
  description = "WAF ブロックログの CloudWatch Log Group 名"
  value       = aws_cloudwatch_log_group.waf.name
}
