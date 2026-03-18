variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where resources are deployed"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for resources that require VPC placement"
  type        = list(string)
}

variable "allowed_bedrock_models" {
  description = "List of Bedrock model ARNs allowed for invocation"
  type        = list(string)
  default = [
    "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
    "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0",
  ]
}

variable "cloudtrail_retention_days" {
  description = "CloudWatch Logs retention for CloudTrail (days)"
  type        = number
  default     = 90
}
