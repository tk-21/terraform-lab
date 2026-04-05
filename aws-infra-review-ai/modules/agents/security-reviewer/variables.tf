variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "dynamodb_table_name" {
  description = "議論ログを保存する DynamoDB テーブル名"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "議論ログを保存する DynamoDB テーブル ARN（IAM ポリシーで使用）"
  type        = string
}
