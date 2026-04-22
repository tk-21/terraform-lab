variable "name_prefix" {
  description = "Resource naming prefix"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "output_bucket_arn" {
  description = "ARN of the Flink output S3 bucket"
  type        = string
}

variable "flink_app_bucket_arn" {
  description = "ARN of the Flink app S3 bucket"
  type        = string
}

variable "github_repo" {
  description = "GitHub repo in owner/repo format"
  type        = string
  default     = "takuya/vpc-lattice-msk-flink-streaming-platform"
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
