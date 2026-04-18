variable "project_name" {
  description = "プロジェクト名。リソース名のプレフィックスとして使用する"
  type        = string
  default     = "iam-least-privilege-advisor"
}

variable "environment" {
  description = "デプロイ環境名（dev / staging / prod）"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "github_token_secret_arn" {
  description = "GitHub Personal Access Token の Secrets Manager ARN"
  type        = string
  sensitive   = true
}

variable "chatwork_secret_arn" {
  description = "Chatwork Token の Secrets Manager ARN"
  type        = string
  sensitive   = true
}

variable "chatwork_room_id" {
  description = "Chatwork 通知先ルーム ID"
  type        = string
}

variable "github_owner" {
  description = "GitHub リポジトリオーナー（ユーザー名または組織名）"
  type        = string
}

variable "github_repo" {
  description = "GitHub リポジトリ名（PR 作成先）"
  type        = string
}

variable "bedrock_model_id" {
  description = "IAM ポリシー生成に使用する Bedrock モデル ID"
  type        = string
  default     = "anthropic.claude-sonnet-4-5"
}
