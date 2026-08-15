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

variable "dynamodb_endpoint_prefix_list_id" {
  description = "Managed prefix list ID for the DynamoDB gateway endpoint"
  type        = string
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
  description = "Model ID for light tasks"
  type        = string
  # Amazon Nova Lite は ap-northeast-1 でオンデマンド推論に対応し、
  # AWS Marketplace のモデルサブスクリプションを必要としない。
  default = "amazon.nova-lite-v1:0"
}

variable "sonnet_model_id" {
  description = "Model ID for complex tasks"
  type        = string
  # dev では Marketplace 依存を避けるため、軽量タスクと同じ Nova Lite を既定にする。
  # AgentCore 移行時などに推論プロファイル対応モデルへ明示的に切り替え可能。
  default = "amazon.nova-lite-v1:0"
}

variable "allowed_model_arns" {
  description = "Bedrock model ARNs the Lambda is allowed to invoke"
  type        = list(string)
  default = [
    "arn:aws:bedrock:ap-northeast-1::foundation-model/amazon.nova-lite-v1:0",
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
