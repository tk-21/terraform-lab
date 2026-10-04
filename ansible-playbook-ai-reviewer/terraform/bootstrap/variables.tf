variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "プロジェクト名（タグ・state の key プレフィックスに使用）"
  type        = string
  default     = "ansible-playbook-ai-reviewer"
}

variable "github_owner" {
  description = "GitHub のユーザー名または組織名"
  type        = string
}

variable "github_repo" {
  description = "ワークフローを実行する GitHub リポジトリ名（モノレポ）"
  type        = string
  default     = "terraform-lab"
}

variable "role_name" {
  description = "GitHub Actions 用 IAM ロール名（64文字以内）"
  type        = string
  default     = "ansible-ai-reviewer-github-actions"

  validation {
    condition     = length(var.role_name) <= 64
    error_message = "IAMロール名は64文字以内にしてください。"
  }
}

variable "function_name" {
  description = "デプロイ対象の Lambda 関数名"
  type        = string
  default     = "ansible-ai-reviewer"
}

variable "state_bucket_name" {
  description = "Terraform state 用 S3 バケット名"
  type        = string
  default     = "terraform-state-ansible-ai-reviewer"
}

variable "create_oidc_provider" {
  description = "GitHub OIDC プロバイダを新規作成するか。アカウントに既にある場合は false（既存を参照）"
  type        = bool
  default     = false
}
