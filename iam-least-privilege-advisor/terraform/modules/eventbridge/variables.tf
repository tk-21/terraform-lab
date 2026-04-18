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

variable "analyzer_trigger_function_arn" {
  description = "analyzer-trigger Lambda 関数の ARN"
  type        = string
}

variable "analyzer_trigger_function_name" {
  description = "analyzer-trigger Lambda 関数の名前"
  type        = string
}

variable "schedule_expression" {
  description = "EventBridge Scheduler のスケジュール式（cron 形式）"
  type        = string
  default     = "cron(0 0 ? * MON *)"
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
