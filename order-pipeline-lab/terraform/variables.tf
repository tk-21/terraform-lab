variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネット CIDR リスト (2AZ分)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}
