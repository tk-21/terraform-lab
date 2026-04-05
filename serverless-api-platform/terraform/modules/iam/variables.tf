# terraform/modules/iam/variables.tf

variable "prefix" {
  description = "リソース名のプレフィックス。例: sap-dev"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名。"
  type        = string
}

variable "account_id" {
  description = "AWS アカウント ID。IAM ポリシーの Resource ARN 構築に使用する。"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "DynamoDB テーブルの ARN。IAM ポリシーで最小権限を設定するために使用する。"
  type        = string
}

variable "audit_bucket_arn" {
  description = "監査ログ用 S3 バケットの ARN。stream-processor の IAM ポリシーで使用する。"
  type        = string
}

variable "audit_kms_key_arn" {
  description = "監査ログ用 S3 バケットの KMS キー ARN。stream-processor が PutObject する際に S3 が kms:GenerateDataKey を呼び出すため GenerateDataKey 権限が必要。"
  type        = string
}
