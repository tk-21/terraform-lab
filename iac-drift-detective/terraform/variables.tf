# AWSリージョン
variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

# Bedrock Claude Sonnet 3.5が利用可能なリージョン
variable "bedrock_region" {
  description = "Bedrock Claude Sonnet 3.5が利用可能なリージョン"
  type        = string
  default     = "us-east-1"
}

# デプロイ環境（dev/prod）
variable "environment" {
  description = "デプロイ環境（dev/prod）"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment は dev または prod を指定してください。"
  }
}

# プロジェクト名（タグ・命名に使用）
variable "project_name" {
  description = "プロジェクト名（タグ・命名に使用）"
  type        = string
  default     = "iac-drift-detective"
}

# GitHubユーザー名またはOrg名
variable "github_owner" {
  description = "GitHubユーザー名またはOrg名"
  type        = string
}

# 対象リポジトリ名
variable "github_repo" {
  description = "対象リポジトリ名"
  type        = string
}

# Chatwork通知先ルームID
variable "chatwork_room_id" {
  description = "Chatwork通知先ルームID"
  type        = string
}

# 監視対象のtfstateが保存されているS3バケット名
variable "monitored_tfstate_bucket" {
  description = "監視対象のtfstateが保存されているS3バケット名"
  type        = string
}

# 監視対象のtfstateのS3キーパス
variable "monitored_tfstate_key" {
  description = "監視対象のtfstateのS3キーパス"
  type        = string
  default     = "terraform.tfstate"
}
