variable "vpc_id" {
  description = "セキュリティグループを作成する VPC の ID"
  type        = string
}

variable "prefix" {
  description = "リソース名プレフィックス（例: cel）"
  type        = string
  validation {
    condition     = length(var.prefix) <= 5
    error_message = "プレフィックスは 5 文字以内にしてください（IAM ロール名 64 文字制限のため）"
  }
}

variable "env" {
  description = "環境名（例: dev / stg / prod）"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
