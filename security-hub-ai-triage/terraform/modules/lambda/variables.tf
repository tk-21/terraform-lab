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

variable "sns_topic_arn" {
  description = "高優先度 Finding の通知先 SNS Topic ARN"
  type        = string
}

variable "bedrock_model_id" {
  description = "使用する Bedrock 推論プロファイル ID"
  type        = string
}
