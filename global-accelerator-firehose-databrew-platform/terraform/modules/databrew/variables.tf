variable "name_prefix" {
  description = "Name prefix for resources"
  type        = string
}

variable "raw_bucket_name" {
  description = "Name of the raw S3 bucket"
  type        = string
}

variable "processed_bucket_name" {
  description = "Name of the processed S3 bucket"
  type        = string
}

variable "databrew_role_arn" {
  description = "ARN of the DataBrew IAM role"
  type        = string
}
