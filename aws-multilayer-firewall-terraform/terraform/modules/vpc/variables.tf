variable "prefix" {
  description = "リソース名プレフィックス (例: amf)"
  type        = string
}

variable "environment" {
  description = "環境名 (例: dev, prod)"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
