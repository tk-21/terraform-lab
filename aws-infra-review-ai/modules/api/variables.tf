variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "input_bucket_id" {
  description = "レビュー入力ファイル S3 バケット名（S3 署名 URL 生成に使用）"
  type        = string
}

variable "input_bucket_arn" {
  description = "レビュー入力ファイル S3 バケット ARN（IAM ポリシーで使用）"
  type        = string
}

variable "review_table_name" {
  description = "議論ログ DynamoDB テーブル名"
  type        = string
}

variable "review_table_arn" {
  description = "議論ログ DynamoDB テーブル ARN（IAM ポリシーで使用）"
  type        = string
}

# Week 2 で Step Functions ARN が確定したら追加する変数
# variable "step_functions_arn" {
#   description = "Step Functions ステートマシン ARN"
#   type        = string
# }
