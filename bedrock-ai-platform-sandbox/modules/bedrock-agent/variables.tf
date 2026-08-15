variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "enable_bedrock_agent" {
  description = "Whether to create Bedrock Agents Classic resources. The action-handler Lambda remains available for a future AgentCore migration."
  type        = bool
  default     = false
}

variable "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID to associate with the agent"
  type        = string
}

variable "guardrail_id" {
  description = "Bedrock Guardrail ID"
  type        = string
}

variable "guardrail_version" {
  description = "Bedrock Guardrail version"
  type        = string
  default     = "DRAFT"
}

variable "usage_table_name" {
  description = "DynamoDB usage table name (for cost summary in action handler)"
  type        = string
}

variable "usage_table_arn" {
  description = "DynamoDB usage table ARN"
  type        = string
}

variable "agent_model_id" {
  description = "Foundation model ID for the Bedrock Agent"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "agent_model_arn" {
  description = "Foundation model ARN for the Bedrock Agent IAM policy"
  type        = string
  default     = "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "idle_session_ttl" {
  description = "Agent idle session TTL in seconds"
  type        = number
  default     = 600
}

variable "lambda_memory_mb" {
  description = "Action handler Lambda memory in MB"
  type        = number
  default     = 256
}
