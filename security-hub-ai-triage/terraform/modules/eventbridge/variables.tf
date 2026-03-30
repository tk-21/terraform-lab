variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "デプロイ環境"
  type        = string
}

variable "lambda_function_arn" {
  description = "ターゲット Lambda 関数の ARN"
  type        = string
}

variable "lambda_function_name" {
  description = "ターゲット Lambda 関数名"
  type        = string
}
