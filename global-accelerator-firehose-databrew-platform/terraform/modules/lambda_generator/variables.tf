variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "generator_role_arn" {
  description = "ARN of the IAM role for Lambda Generator"
  type        = string
}

variable "scheduler_role_arn" {
  description = "ARN of the IAM role for EventBridge Scheduler"
  type        = string
}

variable "accelerator_endpoint" {
  description = "HTTPS endpoint of the Global Accelerator (e.g. https://xxx.awsglobalaccelerator.com)"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for VPC config"
  type        = list(string)
}

variable "sg_lambda_generator_id" {
  description = "Security group ID for Lambda Generator"
  type        = string
}
