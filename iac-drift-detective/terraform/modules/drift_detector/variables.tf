variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "lambda_role_arn" {
  description = "drift-detector LambdaのIAMロールARN（Phase1で作成済み）"
  type        = string
}

variable "monitored_tfstate_bucket" {
  description = "監視対象のtfstateが保存されているS3バケット名"
  type        = string
}

variable "monitored_tfstate_key" {
  description = "監視対象のtfstateファイルのS3キー"
  type        = string
}

variable "monitored_cfn_stacks" {
  description = "監視対象のCloudFormationスタック名（カンマ区切り）"
  type        = string
  default     = ""
}

variable "log_group_name" {
  description = "CloudWatch Logsグループ名（Phase1で作成済み）"
  type        = string
}

variable "tags" {
  description = "リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
