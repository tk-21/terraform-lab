variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "Project name used for naming and tagging"
  type        = string
  default     = "event-driven-pipeline-sandbox"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner name for resource tagging"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "alert_email" {
  description = "Email address for alarm notifications (empty = no subscription)"
  type        = string
  default     = ""
}

variable "job_retention_days" {
  description = "Number of days to retain completed job records in DynamoDB (TTL)"
  type        = number
  default     = 30
}

variable "sqs_visibility_timeout_seconds" {
  description = "SQS message visibility timeout in seconds (must be >= 6x Lambda timeout)"
  type        = number
  default     = 180 # Lambda timeout 30s × 6 = 180s (SQS best practice)
}

variable "max_receive_count" {
  description = "Number of times a message is delivered before moving to DLQ"
  type        = number
  default     = 3
}
