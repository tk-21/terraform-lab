variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
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

variable "alert_email" {
  description = "Email address for budget alert notifications (empty = no subscription)"
  type        = string
  default     = ""
}

variable "warn_percent" {
  description = "Token budget warning threshold in percent"
  type        = number
  default     = 80
}

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget limit in USD"
  type        = string
  default     = "30"
}

variable "schedule_expression" {
  description = "EventBridge schedule for cost check (cron/rate)"
  type        = string
  default     = "rate(1 hour)"
}

variable "lambda_memory_mb" {
  description = "Lambda memory size in MB"
  type        = number
  default     = 256
}
