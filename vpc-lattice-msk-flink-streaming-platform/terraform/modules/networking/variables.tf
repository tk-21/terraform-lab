variable "name_prefix" {
  type        = string
  description = "リソース命名プレフィックス"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "VPC CIDRブロック"
}

variable "private_subnet_cidrs" {
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
  description = "プライベートサブネットCIDRリスト"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
  description = "パブリックサブネットCIDRリスト"
}

variable "availability_zones" {
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
  description = "使用するAZリスト"
}
