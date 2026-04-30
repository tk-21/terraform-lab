variable "prefix" {
  description = "リソース名のプレフィックス"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "region" {
  description = "AWSリージョン"
  type        = string
}

variable "common_tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
}

variable "model_approval_threshold" {
  description = "モデル評価の合格閾値（精度）"
  type        = number
  default     = 0.8
}
