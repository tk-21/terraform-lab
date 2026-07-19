output "securityhub_hub_arn" {
  description = "Security Hub のARN"
  value       = aws_securityhub_account.main.id
}

output "s3_custom_action_arn" {
  description = "S3修復 Custom Action ARN (EventBridgeルールのresourcesフィルタで使用)"
  value       = aws_securityhub_action_target.s3_remediate.arn
}

output "iam_custom_action_arn" {
  description = "IAM修復 Custom Action ARN"
  value       = aws_securityhub_action_target.iam_remediate.arn
}

output "sg_custom_action_arn" {
  description = "SG修復 Custom Action ARN"
  value       = aws_securityhub_action_target.sg_remediate.arn
}

output "rds_custom_action_arn" {
  description = "RDS修復通知 Custom Action ARN"
  value       = aws_securityhub_action_target.rds_remediate.arn
}

output "findings_log_group_name" {
  description = "Security Hub Findings記録用CloudWatch Logsグループ名"
  value       = aws_cloudwatch_log_group.securityhub_findings.name
}

# Custom Action用EventBridgeルールARN (Lambda permissionで使用)
output "s3_custom_action_rule_arn" {
  description = "S3 Custom Action EventBridgeルールARN"
  value       = aws_cloudwatch_event_rule.s3_custom_action.arn
}

output "iam_custom_action_rule_arn" {
  description = "IAM Custom Action EventBridgeルールARN"
  value       = aws_cloudwatch_event_rule.iam_custom_action.arn
}

output "sg_custom_action_rule_arn" {
  description = "SG Custom Action EventBridgeルールARN"
  value       = aws_cloudwatch_event_rule.sg_custom_action.arn
}

output "rds_custom_action_rule_arn" {
  description = "RDS Custom Action EventBridgeルールARN"
  value       = aws_cloudwatch_event_rule.rds_custom_action.arn
}
