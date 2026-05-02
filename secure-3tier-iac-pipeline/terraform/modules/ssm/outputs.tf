output "ssm_document_name" {
  description = "SSM Session Manager document name"
  value       = aws_ssm_document.session_manager.name
}

output "ssm_session_log_group_name" {
  description = "CloudWatch Logs group name for SSM session logs"
  value       = aws_cloudwatch_log_group.ssm_sessions.name
}
