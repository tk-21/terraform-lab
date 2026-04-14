variable "environment" {
  description = "デプロイ環境名"
  type        = string
  default     = "prod"
}

variable "project" {
  description = "プロジェクト識別子"
  type        = string
  default     = "sep"
}

variable "account_id" {
  description = "AWS アカウント ID"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id は 12 桁の数字で指定してください。"
  }
}

variable "alert_email" {
  description = "CloudWatch アラーム通知先メールアドレス"
  type        = string
}

locals {
  lambda_architecture = "arm64"
  lambda_runtime      = "python3.12"

  common_tags = {
    Project     = "serverless-event-pipeline"
    ManagedBy   = "terraform"
    Environment = var.environment
    Owner       = "platform-team"
  }
}
