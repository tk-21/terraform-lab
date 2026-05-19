
variable "prefix" {
  description = "リソース名プレフィックス（例: vnd-hub）"
  type        = string
}

variable "cidr_block" {
  description = "VPCのCIDRブロック"
  type        = string
}

variable "subnets" {
  description = <<-EOT
    サブネット定義マップ。キーはサブネット識別子。
    例: { "private-1a" = { cidr = "10.0.10.0/24", az = "ap-northeast-1a" } }
  EOT
  type = map(object({
    cidr   = string
    az     = string
    public = optional(bool, false)
  }))
}

variable "create_igw" {
  description = "Internet Gatewayを作成するか（Hubのみtrue）"
  type        = bool
  default     = false
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
