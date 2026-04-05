variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "dynamodb_table_name" {
  description = "議論ログ DynamoDB テーブル名（final_report_url の更新に使用）"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "議論ログ DynamoDB テーブル ARN（IAM ポリシーで使用）"
  type        = string
}

variable "reports_bucket_id" {
  description = "HTML レポート保存先 S3 バケット名"
  type        = string
}

variable "reports_bucket_arn" {
  description = "HTML レポート保存先 S3 バケット ARN（IAM ポリシーで使用）"
  type        = string
}
