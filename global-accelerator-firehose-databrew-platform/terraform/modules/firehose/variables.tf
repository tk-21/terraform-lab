variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "firehose_role_arn" {
  description = "ARN of the IAM role for Firehose"
  type        = string
}

variable "raw_bucket_arn" {
  description = "ARN of the raw S3 bucket"
  type        = string
}
