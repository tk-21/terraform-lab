variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "aws_account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "audit_bucket" {
  description = "S3監査ログバケット名 (IAMポリシーのリソース指定に使用)"
  type        = string
}

variable "dlq_arn" {
  description = "SQS DLQ ARN (Lambda修復関数のDLQ送信権限付与に使用)"
  type        = string
}
