variable "environment" {
  description = "環境名"
  type        = string
  default     = "dev"
}

variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
  default     = "amf"
}

variable "aws_region" {
  description = "AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "blocked_ip_list" {
  description = "WAF でブロックする IP アドレスリスト（CIDR 形式）"
  type        = list(string)
  default     = []
}
