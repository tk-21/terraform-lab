variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "environment" {
  description = "環境名"
  type        = string
}

variable "vpc_id" {
  description = "NACL を作成する VPC の ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public サブネット ID マップ (key: AZ suffix)"
  type        = map(string)
}

variable "private_subnet_ids" {
  description = "Private サブネット ID マップ"
  type        = map(string)
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
