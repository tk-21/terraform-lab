# terraform/modules/storage/variables.tf

variable "prefix" {
  description = "リソース名のプレフィックス。例: sap-dev"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名。"
  type        = string
}

variable "account_id" {
  description = "AWS アカウント ID。バケット名のサフィックスとして使用し、グローバル一意性を保証する。"
  type        = string
}
