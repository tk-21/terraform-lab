variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "environment" {
  description = "環境名"
  type        = string
}

variable "common_tags" {
  description = "全リソース共通タグ"
  type        = map(string)
}

variable "lambda_base_role_arn" {
  description = "Lambda共通実行ロールARN"
  type        = string
}

variable "dynamodb_execution_history_table_name" {
  description = "実行履歴DynamoDBテーブル名"
  type        = string
}

variable "dynamodb_approval_requests_table_name" {
  description = "承認リクエストDynamoDBテーブル名"
  type        = string
}

variable "s3_reports_bucket_name" {
  description = "レポート保存S3バケット名"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}
