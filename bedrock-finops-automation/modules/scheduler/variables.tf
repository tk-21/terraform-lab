variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name (dev / stg / prod)"
  type        = string
}

variable "state_machine_arn" {
  description = "Step Functions state machine ARN to trigger"
  type        = string
}

variable "schedule_expression" {
  description = "EventBridge スケジュール式（デフォルト: 毎月1日 00:00 UTC = 09:00 JST）"
  type        = string
  default     = "cron(0 0 1 * ? *)"
}

variable "enabled" {
  description = "スケジュールルールの有効 / 無効（開発中は無効にして誤発動を防ぐ）"
  type        = bool
  default     = true
}
