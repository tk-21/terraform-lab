variable "prefix" {
  description = "リソース名プレフィックス（例: cel）"
  type        = string
}

variable "env" {
  description = "環境名（例: dev）"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
