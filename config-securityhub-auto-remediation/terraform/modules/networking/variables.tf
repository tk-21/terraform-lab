variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネットのCIDRリスト (2 AZ分)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "availability_zones" {
  description = "使用するAZリスト"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}
