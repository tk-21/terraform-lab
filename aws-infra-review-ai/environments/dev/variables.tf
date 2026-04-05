# =============================================================================
# 環境変数定義
# =============================================================================

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "デプロイ環境名（dev / stg / prd）"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "プロジェクト名（リソース名プレフィックスに使用）"
  type        = string
  default     = "aws-infra-review-ai"
}

variable "owner" {
  description = "リソースオーナー（タグ用）"
  type        = string
  default     = "your-name"
}

variable "cost_center" {
  description = "コストセンター（タグ用）"
  type        = string
  default     = "personal"
}

variable "chatwork_api_token" {
  description = "Chatwork API トークン（Week 3 で使用）"
  type        = string
  sensitive   = true
  default     = ""
}

variable "chatwork_room_id" {
  description = "Chatwork 通知先ルームID（Week 3 で使用）"
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = <<-EOT
    CloudWatch アラームの通知先メールアドレス（任意）。
    設定すると SNS Email サブスクリプションが作成され、SF 失敗・Lambda エラーをメール通知する。
    apply 後に AWS から確認メールが届くので承認が必要。
  EOT
  type    = string
  default = ""
}

variable "github_repository" {
  description = <<-EOT
    GitHub Actions OIDC の対象リポジトリ（"org/repo" 形式）。
    例: "your-org/aws-infra-review-ai"
    IAM ロールの assume 条件に使用する。
  EOT
  type    = string
  default = "your-org/aws-infra-review-ai"
}
