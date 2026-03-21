variable "project" {
  description = "Project name used for naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "athena_results_bucket_arn" {
  description = "ARN of the S3 bucket for Athena query results"
  type        = string
}

variable "athena_results_bucket_id" {
  description = "Name of the S3 bucket for Athena query results"
  type        = string
}

variable "processed_bucket_id" {
  description = "S3 processed zone bucket name (for Named Query DDL reference)"
  type        = string
}

variable "glue_database_name" {
  description = "Glue Catalog database name"
  type        = string
}

variable "athena_bytes_scanned_cutoff" {
  description = "Max bytes scanned per query (cost guard)"
  type        = number
  default     = 1073741824 # 1 GB
}
