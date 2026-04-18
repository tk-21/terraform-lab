variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

variable "analyzer_trigger_role_arn" {
  description = "analyzer-trigger Lambda 実行ロールの ARN"
  type        = string
}

variable "policy_advisor_role_arn" {
  description = "policy-advisor Lambda 実行ロールの ARN"
  type        = string
}

variable "results_bucket_name" {
  description = "Analyzer 結果保存 S3 バケット名"
  type        = string
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
  description = "GitHub リポジトリオーナー"
  type        = string
}

variable "github_repo" {
  description = "GitHub リポジトリ名"
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock モデル ID"
  type        = string
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
