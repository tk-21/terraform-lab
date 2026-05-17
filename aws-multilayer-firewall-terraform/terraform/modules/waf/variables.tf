variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "alb_arn" {
  description = "WAF をアタッチする ALB の ARN"
  type        = string
}

variable "blocked_ip_list" {
  description = "ブロック対象の IP アドレスリスト（CIDR 形式）"
  type        = list(string)
  default     = []
}
