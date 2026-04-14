variable "environment" {
  description = "デプロイ環境名（dev / staging / prod）"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment は dev / staging / prod のいずれかを指定してください。"
  }
}

variable "project" {
  description = "プロジェクト識別子。リソース命名の prefix に使用する。"
  type        = string
  default     = "sep"
}

variable "account_id" {
  description = "AWS アカウント ID。S3 バケット名のグローバル一意性を確保するために使用する。"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id は 12 桁の数字で指定してください。"
  }
}

variable "github_repository" {
  description = <<-EOT
    GitHub リポジトリ（owner/repo 形式）。
    OIDC 信頼ポリシーの sub クレーム検証に使用する。
    例: "myorg/serverless-event-pipeline"
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository は owner/repo 形式で指定してください（例: myorg/my-repo）。"
  }
}

variable "alert_email" {
  description = "CloudWatch アラーム通知先のメールアドレス（SNS サブスクリプション）"
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "有効なメールアドレス形式で指定してください。"
  }
}

# Lambda アーキテクチャ設定
# arm64（Graviton2）は x86_64 比で約 20% のコスト削減が見込める。
locals {
  lambda_architecture = "arm64"
  lambda_runtime      = "python3.12"

  # 全リソース共通タグ
  common_tags = {
    Project     = "serverless-event-pipeline"
    ManagedBy   = "terraform"
    Environment = var.environment
    Owner       = "platform-team"
  }
}
