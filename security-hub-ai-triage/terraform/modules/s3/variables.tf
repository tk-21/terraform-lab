variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境"
  type        = string
}

variable "force_destroy" {
  description = "true の場合、destroy 時にバケット内の全オブジェクト・全バージョンを削除する"
  type        = bool
  default     = false
}
