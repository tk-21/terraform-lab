variable "prefix" {
  description = "リソース名プレフィックス (例: giop = gpu-inference-operator)"
  type        = string
  validation {
    condition     = length(var.prefix) <= 8
    error_message = "プレフィックスは8文字以内 (IAMロール名64文字制限への余裕確保のため)"
  }
}

variable "env" {
  description = "環境識別子 (dev / stg / prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネットのCIDRリスト (EKSノード・Podが配置される)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "パブリックサブネットのCIDRリスト (ALB専用。NAT Gatewayは置かない)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "azs" {
  description = "使用するAZリスト"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
