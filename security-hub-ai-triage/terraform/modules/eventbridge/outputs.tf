output "rule_arn" {
  description = "EventBridge ルールの ARN"
  value       = aws_cloudwatch_event_rule.security_hub_findings.arn
}

output "rule_name" {
  description = "EventBridge ルール名"
  value       = aws_cloudwatch_event_rule.security_hub_findings.name
}
