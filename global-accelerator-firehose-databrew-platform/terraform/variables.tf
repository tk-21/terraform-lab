variable "project_name" {
  description = "Project short name"
  type        = string
  default     = "gaf"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "backend_bucket" {
  description = "S3 bucket name for Terraform state"
  type        = string
}

variable "backend_key" {
  description = "S3 key for Terraform state"
  type        = string
  default     = "gaf/terraform.tfstate"
}
