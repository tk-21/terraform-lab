variable "prefix" {
  description = "リソース名プレフィックス (例: ecl)"
  type        = string
  validation {
    condition     = length(var.prefix) <= 8
    error_message = "プレフィックスは8文字以内にしてください (IAMロール名64文字制限のため)"
  }
}

variable "env" {
  description = "環境名 (例: dev, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID (IAM ポリシーの Resource ARN に使用)"
  type        = string
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
