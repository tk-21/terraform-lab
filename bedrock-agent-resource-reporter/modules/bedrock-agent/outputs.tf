output "agent_id" {
  description = "Bedrock Agent ID"
  value       = aws_bedrockagent_agent.this.id
}

output "agent_arn" {
  description = "Bedrock Agent ARN"
  value       = aws_bedrockagent_agent.this.agent_arn
}

output "agent_alias_id" {
  description = "Bedrock Agent Alias ID"
  value       = aws_bedrockagent_agent_alias.this.agent_alias_id
}
