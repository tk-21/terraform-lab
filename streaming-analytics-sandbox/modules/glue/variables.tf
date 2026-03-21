variable "project" {
  description = "Project name used for naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "raw_bucket_id" {
  description = "S3 raw zone bucket name"
  type        = string
}

variable "raw_bucket_arn" {
  description = "S3 raw zone bucket ARN"
  type        = string
}

variable "processed_bucket_id" {
  description = "S3 processed zone bucket name"
  type        = string
}

variable "processed_bucket_arn" {
  description = "S3 processed zone bucket ARN"
  type        = string
}

variable "scripts_bucket_id" {
  description = "S3 scripts bucket name"
  type        = string
}

variable "scripts_bucket_arn" {
  description = "S3 scripts bucket ARN"
  type        = string
}
