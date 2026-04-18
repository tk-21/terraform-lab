variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "unused_access_age" {
  description = "未使用アクセスとみなすまでの日数"
  type        = number
  default     = 90
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
