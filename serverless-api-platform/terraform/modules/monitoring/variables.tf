# terraform/modules/monitoring/variables.tf

variable "prefix" {
  description = "リソース名のプレフィックス。例: sap-dev"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名。"
  type        = string
}

variable "alert_email" {
  description = "アラーム通知先メールアドレス。"
  type        = string
}

variable "lambda_function_names" {
  description = "監視対象の Lambda 関数名リスト。"
  type        = list(string)
}

variable "api_gateway_id" {
  description = "API Gateway REST API の ID。"
  type        = string
}
