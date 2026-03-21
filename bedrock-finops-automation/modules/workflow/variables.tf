variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name (dev / stg / prod)"
  type        = string
}

# ── 各 Lambda の ARN（Step Functions が InvokeFunction するために必要）──

variable "collector_lambda_arn" {
  description = "Collector Lambda ARN"
  type        = string
}

variable "anomaly_detector_lambda_arn" {
  description = "Anomaly detector Lambda ARN"
  type        = string
}

variable "ai_reporter_lambda_arn" {
  description = "AI reporter Lambda ARN"
  type        = string
}

variable "html_formatter_lambda_arn" {
  description = "HTML formatter Lambda ARN"
  type        = string
}

variable "chatwork_notifier_lambda_arn" {
  description = "Chatwork notifier Lambda ARN"
  type        = string
}

variable "log_level" {
  description = "Step Functions CloudWatch Logs のログレベル（ALL | ERROR | FATAL | OFF）"
  type        = string
  default     = "ERROR"
}
