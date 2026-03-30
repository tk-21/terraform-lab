# terraform/environments/prod/variables.tf
#
# prod 環境の変数定義。dev と同じ変数セットだが、デフォルト値が prod 向け。

variable "environment" {
  type    = string
  default = "prod"
}

variable "project" {
  type    = string
  default = "sap"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id は12桁の数字で指定してください。"
  }
}

variable "alert_email" {
  type = string
  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "有効なメールアドレスを指定してください。"
  }
}

variable "allowed_ips" {
  description = "prod 環境では本番クライアントの IP を必ず設定すること。"
  type        = list(string)
  default     = []
}
