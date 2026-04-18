variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "results_bucket_arn" {
  description = "Analyzer 結果保存 S3 バケットの ARN"
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

variable "bedrock_model_id" {
  description = "Bedrock モデル ID"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
