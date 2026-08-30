variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境"
  type        = string
}

variable "notification_email" {
  description = "SNS メール通知を購読するメールアドレス"
  type        = string
  sensitive   = true
}
