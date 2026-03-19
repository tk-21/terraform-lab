variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "jobs_table_name" {
  description = "DynamoDB jobs table name"
  type        = string
}

variable "jobs_table_arn" {
  description = "DynamoDB jobs table ARN"
  type        = string
}

variable "notification_topic_arn" {
  description = "SNS topic ARN for job completion/failure notifications"
  type        = string
}

variable "log_retention_days" {
  description = "Step Functions execution log retention in days"
  type        = number
  default     = 14
}
