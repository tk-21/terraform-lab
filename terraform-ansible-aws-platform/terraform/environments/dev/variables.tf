variable "project" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "環境名"
  type        = string
}

variable "alert_email" {
  description = "CloudWatchアラート通知先メールアドレス"
  type        = string
}
