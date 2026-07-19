variable "environment" {
  description = "デプロイ環境名 (dev / stg / prod)"
  type        = string
}

variable "dlq_queue_name" {
  description = "監視対象のSQS DLQキュー名 (audit moduleから)"
  type        = string
}
