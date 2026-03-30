# terraform/modules/dynamodb/variables.tf

variable "prefix" {
  description = "リソース名のプレフィックス。例: sap-dev"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名。"
  type        = string
}

variable "enable_pitr" {
  description = "ポイントインタイムリカバリの有効化。prod では true を推奨。"
  type        = bool
  default     = false
}

variable "enable_dax" {
  description = "DAX（DynamoDB Accelerator）の有効化。prod のみ true にする。"
  type        = bool
  default     = false
}
