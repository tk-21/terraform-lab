variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境"
  type        = string
}

variable "lambda_role_arn" {
  description = "Lambda 実行ロールの ARN"
  type        = string
}

variable "dynamodb_table_name" {
  description = "重複排除 DynamoDB テーブル名"
  type        = string
}

variable "s3_bucket_name" {
  description = "レポート保存 S3 バケット名"
  type        = string
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
}
