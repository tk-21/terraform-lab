variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "raw_bucket_arn" {
  description = "ARN of the raw S3 bucket"
  type        = string
}

variable "processed_bucket_arn" {
  description = "ARN of the processed S3 bucket"
  type        = string
}

variable "firehose_stream_arn" {
  description = "Firehose delivery stream ARN - set after firehose module is created"
  type        = string
  default     = "arn:aws:firehose:ap-northeast-1:000000000000:deliverystream/placeholder"
}

variable "generator_lambda_arn" {
  description = "Generator Lambda ARN - set after lambda_generator module is created"
  type        = string
  default     = "arn:aws:lambda:ap-northeast-1:000000000000:function:placeholder"
}

variable "state_bucket_arn" {
  description = "Terraform state S3 bucket ARN for GitHub Actions"
  type        = string
}
