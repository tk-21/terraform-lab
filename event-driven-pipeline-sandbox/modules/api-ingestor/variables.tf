variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "input_queue_url" {
  description = "SQS input queue URL"
  type        = string
}

variable "input_queue_name" {
  description = "SQS input queue name"
  type        = string
}

variable "input_queue_arn" {
  description = "SQS input queue ARN"
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

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "v1"
}
