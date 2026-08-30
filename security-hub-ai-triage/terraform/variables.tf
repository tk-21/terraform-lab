variable "project_name" {
  description = "プロジェクト名。リソース命名に使用する"
  type        = string
  default     = "security-hub-ai-triage"
}

variable "environment" {
  description = "デプロイ環境（dev / stg / prod）"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "sns_notification_email" {
  description = "高優先度 Finding の SNS メール通知先"
  type        = string
  sensitive   = true
}

variable "bedrock_model_id" {
  description = "使用する Bedrock 推論プロファイル ID"
  type        = string
  default     = "jp.anthropic.claude-haiku-4-5-20251001-v1:0"

  validation {
    condition     = can(regex("^jp\\.anthropic\\.claude-haiku-4-5-20251001-v1:0$", var.bedrock_model_id))
    error_message = "東京リージョン向けの Claude Haiku 4.5 推論プロファイル ID を指定してください。"
  }
}

variable "s3_force_destroy" {
  description = "true の場合、destroy 時にレポートバケット内の全オブジェクト・全バージョンを削除する"
  type        = bool
  default     = false
}
