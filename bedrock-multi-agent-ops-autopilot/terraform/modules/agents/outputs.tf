output "guardrail_id" {
  description = "Bedrock Guardrail ID"
  value       = aws_bedrock_guardrail.ops_guardrail.guardrail_id
}

output "guardrail_arn" {
  description = "Bedrock Guardrail ARN"
  value       = aws_bedrock_guardrail.ops_guardrail.guardrail_arn
}

output "incident_investigator_agent_id" {
  description = "Incident Investigator Agent ID"
  value       = aws_bedrock_agent.incident_investigator.agent_id
}

output "incident_investigator_agent_alias_id" {
  description = "Incident Investigator Agent エイリアスID"
  value       = aws_bedrock_agent_alias.incident_investigator.agent_alias_id
}

output "cost_optimizer_agent_id" {
  description = "Cost Optimizer Agent ID"
  value       = aws_bedrock_agent.cost_optimizer.agent_id
}

output "cost_optimizer_agent_alias_id" {
  description = "Cost Optimizer Agent エイリアスID"
  value       = aws_bedrock_agent_alias.cost_optimizer.agent_alias_id
}

output "remediation_agent_id" {
  description = "Remediation Agent ID"
  value       = aws_bedrock_agent.remediation.agent_id
}

output "remediation_agent_alias_id" {
  description = "Remediation Agent エイリアスID"
  value       = aws_bedrock_agent_alias.remediation.agent_alias_id
}

output "reporter_agent_id" {
  description = "Reporter Agent ID"
  value       = aws_bedrock_agent.reporter.agent_id
}

output "reporter_agent_alias_id" {
  description = "Reporter Agent エイリアスID"
  value       = aws_bedrock_agent_alias.reporter.agent_alias_id
}

output "sub_agent_role_arn" {
  description = "Sub-agent共通IAMロールARN"
  value       = aws_iam_role.sub_agent.arn
}

output "supervisor_agent_id" {
  description = "Supervisor Agent ID"
  value       = aws_bedrock_agent.supervisor.agent_id
}

output "supervisor_agent_alias_id" {
  description = "Supervisor Agent エイリアスID"
  value       = aws_bedrock_agent_alias.supervisor.agent_alias_id
}
