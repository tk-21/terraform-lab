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

variable "input_queue_arn" {
  description = "SQS input queue ARN (event source for this Lambda)"
  type        = string
}

variable "input_queue_url" {
  description = "SQS input queue URL"
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

variable "state_machine_arn" {
  description = "Step Functions state machine ARN to start"
  type        = string
}

variable "lambda_timeout_seconds" {
  description = "Lambda function timeout (must be < SQS visibility timeout)"
  type        = number
  default     = 25
}

variable "batch_size" {
  description = "SQS event source mapping batch size"
  type        = number
  default     = 10
}

variable "job_retention_days" {
  description = "TTL for job records in days"
  type        = number
  default     = 30
}
