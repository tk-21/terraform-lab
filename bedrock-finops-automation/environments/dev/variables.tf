variable "aws_region" {
  description = "AWS region for resource deployment"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "Environment name (dev / stg / prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "bedrock-finops-automation"
}

variable "owner" {
  description = "Resource owner (used for tagging)"
  type        = string
  default     = "your-name"
}

variable "cost_center" {
  description = "Cost center code (used for tagging)"
  type        = string
  default     = "personal"
}
