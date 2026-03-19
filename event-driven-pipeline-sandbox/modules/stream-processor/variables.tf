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

variable "jobs_table_stream_arn" {
  description = "DynamoDB Streams ARN for the jobs table"
  type        = string
}

variable "metrics_table_name" {
  description = "DynamoDB metrics table name"
  type        = string
}

variable "metrics_table_arn" {
  description = "DynamoDB metrics table ARN"
  type        = string
}

variable "metrics_retention_days" {
  description = "Retention period for metrics records in days"
  type        = number
  default     = 90
}

variable "batch_size" {
  description = "DynamoDB Streams event source mapping batch size"
  type        = number
  default     = 100
}
