output "agent_id" {
  description = "Bedrock Agent ID. Null when Bedrock Agents Classic is disabled."
  value       = try(aws_bedrockagent_agent.main[0].agent_id, null)
}

output "agent_arn" {
  description = "Bedrock Agent ARN. Null when Bedrock Agents Classic is disabled."
  value       = try(aws_bedrockagent_agent.main[0].agent_arn, null)
}

output "agent_name" {
  description = "Bedrock Agent name. Null when Bedrock Agents Classic is disabled."
  value       = try(aws_bedrockagent_agent.main[0].agent_name, null)
}

output "action_handler_function_name" {
  description = "Action handler Lambda function name"
  value       = aws_lambda_function.action_handler.function_name
}

output "action_handler_function_arn" {
  description = "Action handler Lambda function ARN"
  value       = aws_lambda_function.action_handler.arn
}

output "action_handler_log_group" {
  description = "CloudWatch Log Group for the action handler Lambda"
  value       = aws_cloudwatch_log_group.action_handler.name
}
