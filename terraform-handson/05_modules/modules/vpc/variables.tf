variable "prefix" {
  description = "リソース名プレフィックス (例: handson)"
  type        = string
}

variable "env" {
  description = "環境名 (dev / stg / prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPCのCIDRブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "パブリックサブネットの定義。キーにAZ名、値にCIDRを指定する"
  type        = map(string)
  # 例:
  # {
  #   "ap-northeast-1a" = "10.0.1.0/24"
  #   "ap-northeast-1c" = "10.0.2.0/24"
  # }
}

variable "private_subnets" {
  description = "プライベートサブネットの定義。キーにAZ名、値にCIDRを指定する"
  type        = map(string)
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
