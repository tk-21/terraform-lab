variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for Lambda VPC configuration"
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR block for security group rules"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Lambda VPC configuration"
  type        = list(string)
}

variable "guardrail_id" {
  description = "Bedrock Guardrail ID"
  type        = string
}

variable "guardrail_arn" {
  description = "Bedrock Guardrail ARN"
  type        = string
}

variable "guardrail_version" {
  description = "Bedrock Guardrail version to apply"
  type        = string
  default     = "DRAFT"
}

variable "tenant_table_name" {
  description = "DynamoDB table name for tenant configuration"
  type        = string
}

variable "tenant_table_arn" {
  description = "DynamoDB table ARN for tenant configuration"
  type        = string
}

variable "usage_table_name" {
  description = "DynamoDB table name for token usage tracking"
  type        = string
}

variable "usage_table_arn" {
  description = "DynamoDB table ARN for token usage tracking"
  type        = string
}

variable "haiku_model_id" {
  description = "Model ID for Claude Haiku (light tasks)"
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

variable "sonnet_model_id" {
  description = "Model ID for Claude Sonnet (complex tasks)"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "allowed_model_arns" {
  description = "Bedrock model ARNs the Lambda is allowed to invoke"
  type        = list(string)
  default = [
    "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
    "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0",
  ]
}

variable "lambda_memory_mb" {
  description = "Lambda memory size in MB (max 512 per cost policy)"
  type        = number
  default     = 512
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 30
}
