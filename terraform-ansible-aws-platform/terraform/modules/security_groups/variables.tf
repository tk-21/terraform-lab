variable "project" {
  type        = string
  description = "プロジェクト名（リソース命名に使用）"
}

variable "environment" {
  type        = string
  description = "環境名（dev / stg / prod）"
}

variable "vpc_id" {
  type        = string
  description = "Security Groupを作成するVPCのID"
}
