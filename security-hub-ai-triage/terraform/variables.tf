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

variable "chatwork_secret_arn" {
  description = "Chatwork Token を格納した Secrets Manager の ARN"
  type        = string
  sensitive   = true
}

variable "chatwork_room_id" {
  description = "通知先 Chatwork ルーム ID"
  type        = string
}

variable "bedrock_model_id" {
  description = "使用する Bedrock モデル ID"
  type        = string
  default     = "anthropic.claude-haiku-4-5"
}
