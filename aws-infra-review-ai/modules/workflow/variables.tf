variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "input_bucket_id" {
  description = "レビュー入力ファイル S3 バケット名（S3 イベント通知の設定に使用）"
  type        = string
}

variable "input_bucket_arn" {
  description = "レビュー入力ファイル S3 バケット ARN（IAM ポリシーで使用）"
  type        = string
}

variable "review_table_name" {
  description = "議論ログ DynamoDB テーブル名（Step Functions SDK 統合で使用）"
  type        = string
}

variable "review_table_arn" {
  description = "議論ログ DynamoDB テーブル ARN（IAM ポリシーで使用）"
  type        = string
}

# 4 エージェント Lambda の ARN（Step Functions が呼び出す）
variable "security_reviewer_arn" {
  description = "security-reviewer Lambda ARN"
  type        = string
}

variable "cost_reviewer_arn" {
  description = "cost-reviewer Lambda ARN"
  type        = string
}

variable "reliability_reviewer_arn" {
  description = "reliability-reviewer Lambda ARN"
  type        = string
}

variable "operations_reviewer_arn" {
  description = "operations-reviewer Lambda ARN"
  type        = string
}

variable "supervisor_arn" {
  description = "supervisor Lambda ARN（4 エージェントの結果を統合）"
  type        = string
}

variable "report_generator_arn" {
  description = "report-generator Lambda ARN（HTML レポート生成 + S3 保存）"
  type        = string
}

variable "chatwork_notifier_arn" {
  description = "chatwork-notifier Lambda ARN（Chatwork 通知）"
  type        = string
}
