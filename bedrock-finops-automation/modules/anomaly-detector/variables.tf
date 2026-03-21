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

variable "medium_threshold_pct" {
  description = "前月比コスト増加率(%)でMEDIUMアラートを発火する閾値"
  type        = number
  default     = 20
}

variable "high_threshold_pct" {
  description = "前月比コスト増加率(%)でHIGHアラートを発火する閾値"
  type        = number
  default     = 50
}

variable "service_concentration_threshold_pct" {
  description = "単一サービスのコスト集中度(%)でアラートを発火する閾値"
  type        = number
  default     = 60
}
