variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "lifecycle_days" {
  description = "オブジェクトの有効期限（日）。コスト削減のため30日で自動削除"
  type        = number
  default     = 30
}
