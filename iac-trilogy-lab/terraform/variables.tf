variable "aws_account_id" {
  description = "AWSアカウントID（S3バケット名のサフィックスに使用）"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id は12桁の数字でなければなりません。"
  }
}

variable "notification_email" {
  description = "Budgets・CloudWatchアラート通知先メールアドレス"
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.notification_email))
    error_message = "有効なメールアドレスを指定してください。"
  }
}
