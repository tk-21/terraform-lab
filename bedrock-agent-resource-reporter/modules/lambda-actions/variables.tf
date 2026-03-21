variable "region" {
  description = "AWS region"
  type        = string
}

variable "reports_bucket_name" {
  description = "S3 bucket name for reports"
  type        = string
}

variable "reports_bucket_arn" {
  description = "S3 bucket ARN for reports"
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for notifications"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used for S3 SSE-KMS encryption (required for report_writer to PutObject)"
  type        = string
}
