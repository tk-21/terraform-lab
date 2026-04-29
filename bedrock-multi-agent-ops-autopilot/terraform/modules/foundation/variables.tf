variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "common_tags" {
  description = "共通タグ"
  type        = map(string)
}
