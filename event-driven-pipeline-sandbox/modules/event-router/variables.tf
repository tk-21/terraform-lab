variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr_block" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "state_machine_arn" {
  description = "Step Functions state machine ARN to monitor for failures"
  type        = string
}

variable "jobs_table_name" {
  description = "DynamoDB jobs table name"
  type        = string
}

variable "jobs_table_arn" {
  description = "DynamoDB jobs table ARN"
  type        = string
}

variable "alert_topic_arn" {
  description = "SNS topic ARN for operational alerts"
  type        = string
}

variable "alert_email" {
  description = "Alert email (informational; subscription managed in messaging module)"
  type        = string
  default     = ""
}

variable "stuck_job_hours" {
  description = "Hours before a PENDING job is considered stuck"
  type        = number
  default     = 1
}

variable "cleanup_schedule" {
  description = "EventBridge schedule expression for the cleanup rule"
  type        = string
  default     = "rate(1 hour)"
}
