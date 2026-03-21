variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name (dev / stg / prod)"
  type        = string
}

variable "report_bucket_name" {
  description = "S3 bucket name for storing cost reports"
  type        = string
}

variable "report_bucket_arn" {
  description = "S3 bucket ARN for IAM policy"
  type        = string
}

variable "dynamodb_table_name" {
  description = "DynamoDB table name for report history"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "DynamoDB table ARN for IAM policy"
  type        = string
}

variable "lambda_memory_size" {
  description = "Lambda memory size in MB (max 512 per cost optimization rule)"
  type        = number
  default     = 256
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 60
}
