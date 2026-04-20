# =============================================================================
# EventBridgeモジュール 変数定義
# =============================================================================

variable "project" {
  description = "プロジェクト名（全リソースの命名プレフィックスに使用）"
  type        = string
}

variable "environment" {
  description = "環境名（dev / stg / prod）"
  type        = string
}

variable "lambda_function_arn" {
  description = "FISイベントを受信するOrchestratorLambdaのARN"
  type        = string
}

variable "lambda_function_name" {
  description = "FISイベントを受信するOrchestratorLambdaの関数名"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
}
