variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

variable "bedrock_model_id" {
  description = "使用する Bedrock モデル ID"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "重複排除 DynamoDB テーブルの ARN"
  type        = string
}

variable "s3_bucket_arn" {
  description = "レポート保存 S3 バケットの ARN"
  type        = string
}

variable "chatwork_secret_arn" {
  description = "Chatwork Token を格納した Secrets Manager の ARN"
  type        = string
  sensitive   = true
}
