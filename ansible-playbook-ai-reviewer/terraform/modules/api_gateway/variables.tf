variable "api_name" {
  description = "API Gateway REST API名"
  type        = string
}

variable "stage_name" {
  description = "API Gatewayのステージ名"
  type        = string
  default     = "v1"
}

variable "lambda_invoke_arn" {
  description = "統合先Lambda関数の呼び出しARN"
  type        = string
}

variable "lambda_function_name" {
  description = "統合先Lambda関数名（Lambda Permission用）"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

variable "environment" {
  description = "デプロイ環境"
  type        = string
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
