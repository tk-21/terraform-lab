variable "project" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "環境名 (dev/stg/prod)"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALBのARNサフィックス（CloudWatchメトリクス用）"
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target GroupのARNサフィックス（CloudWatchメトリクス用）"
  type        = string
}

variable "alert_email" {
  description = "アラート通知先メールアドレス"
  type        = string
}
