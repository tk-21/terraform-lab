variable "name_prefix" {
  description = "リソース命名プレフィックス（例: handson-dev）"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidrは有効なCIDR形式で指定してください。"
  }
}

variable "az_count" {
  description = "使用するAZ数（最大3）"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "az_countは1から3の間で指定してください。"
  }
}
