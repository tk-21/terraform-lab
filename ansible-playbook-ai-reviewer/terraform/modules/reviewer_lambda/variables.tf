variable "function_name" {
  description = "Lambda関数名"
  type        = string
}

variable "role_arn" {
  description = "Lambda実行ロールのARN"
  type        = string
}

variable "timeout" {
  description = "Lambda関数のタイムアウト（秒）"
  type        = number
  default     = 300
}

variable "memory" {
  description = "Lambda関数のメモリサイズ（MB）"
  type        = number
  default     = 512
}

variable "github_token_ssm_path" {
  description = "GitHub TokenのSSMパラメータパス"
  type        = string
}

variable "bedrock_region" {
  description = "Bedrockを呼び出すリージョン"
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
