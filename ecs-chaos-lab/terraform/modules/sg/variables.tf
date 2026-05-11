variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "vpc_id" {
  description = "セキュリティグループを作成する VPC ID"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
