variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for security group placement"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN — EC2 IAM policy で Decrypt/GenerateDataKey を制限するために使用"
  type        = string
}

variable "rds_secret_arn_prefix" {
  description = "Secrets Manager ARN prefix for RDS secrets (ata-prod/rds/*)"
  type        = string
  default     = "ata-prod/rds/*"
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
