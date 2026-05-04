variable "admin_email" {
  description = "CloudWatchアラーム通知先の管理者メールアドレス"
  type        = string
}

variable "bounce_handler_function_name" {
  description = "CloudWatchダッシュボードに表示するbounce_handler Lambda関数名"
  type        = string
}

variable "spam_handler_function_name" {
  description = "CloudWatchダッシュボードに表示するspam_handler Lambda関数名"
  type        = string
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
