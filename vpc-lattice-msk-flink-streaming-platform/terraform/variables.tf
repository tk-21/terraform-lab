variable "project_name" {
  type    = string
  default = "streaming"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "aws_account_id" {
  type        = string
  description = "AWSアカウントID"
  sensitive   = false
}

variable "backend_bucket" {
  type        = string
  description = "Terraform stateを保存するS3バケット名"
}

variable "backend_key" {
  type    = string
  default = "vpc-lattice-msk-flink/terraform.tfstate"
}
