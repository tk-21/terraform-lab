output "agent_id" {
  description = "Bedrock Agent ID"
  value       = module.bedrock_agent.agent_id
}

output "agent_alias_id" {
  description = "Bedrock Agent Alias ID"
  value       = module.bedrock_agent.agent_alias_id
}

output "agent_arn" {
  description = "Bedrock Agent ARN"
  value       = module.bedrock_agent.agent_arn
}

output "reports_bucket_name" {
  description = "S3 bucket name for reports"
  value       = aws_s3_bucket.reports.id
}

output "reports_bucket_arn" {
  description = "S3 bucket ARN for reports"
  value       = aws_s3_bucket.reports.arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN for notifications"
  value       = aws_sns_topic.notifications.arn
}
