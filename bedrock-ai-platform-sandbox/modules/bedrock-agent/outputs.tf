output "agent_id" {
  description = "Bedrock Agent ID"
  value       = aws_bedrockagent_agent.main.agent_id
}

output "agent_arn" {
  description = "Bedrock Agent ARN"
  value       = aws_bedrockagent_agent.main.agent_arn
}

output "agent_name" {
  description = "Bedrock Agent name"
  value       = aws_bedrockagent_agent.main.agent_name
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
