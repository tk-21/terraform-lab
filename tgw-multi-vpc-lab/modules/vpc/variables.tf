variable "vpc_name" {
  description = "VPC識別名（例: hub, spoke-a）"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック"
  type        = string
}

variable "az_count" {
  description = "使用するAZ数"
  type        = number
  default     = 2
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネットCIDRのリスト"
  type        = list(string)
}

variable "tgw_subnet_cidrs" {
  description = "TGWアタッチメント専用サブネットCIDRのリスト（/28推奨）"
  type        = list(string)
}

variable "enable_dns_hostnames" {
  description = "DNSホスト名を有効化するか"
  type        = bool
  default     = true
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
