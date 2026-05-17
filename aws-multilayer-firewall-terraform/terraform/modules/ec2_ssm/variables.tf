variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "environment" {
  description = "環境名"
  type        = string
}

variable "subnet_id" {
  description = "EC2 を起動する Private サブネット ID"
  type        = string
}

variable "security_group_id" {
  description = "EC2 に付与する SSM 用 Security Group ID"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
