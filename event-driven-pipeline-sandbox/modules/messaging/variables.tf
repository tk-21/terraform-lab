variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "sqs_visibility_timeout_seconds" {
  description = "Visibility timeout for the input queue. Must be >= Lambda timeout."
  type        = number
  default     = 30
}

variable "max_receive_count" {
  description = "Number of times a message is delivered before moving to DLQ"
  type        = number
  default     = 3
}

variable "message_retention_seconds" {
  description = "SQS message retention period in seconds"
  type        = number
  default     = 345600 # 4 days
}

variable "alert_email" {
  description = "Email address to subscribe to the alert SNS topic"
  type        = string
  default     = ""
}
