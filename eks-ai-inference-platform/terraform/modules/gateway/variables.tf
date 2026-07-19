variable "project" {
  description = "プロジェクト識別子 (例: eks-ai-inf)"
  type        = string
  validation {
    condition     = length(var.project) <= 20
    error_message = "project は20文字以内にしてください (IAMロール名64文字制限のため)"
  }
}

variable "environment" {
  description = "環境名 (dev / stg / prod)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDCプロバイダーARN (AI Gateway IRSA の信頼ポリシーに使用)"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDCプロバイダーURL (ホスト名のみ、https:// なし)"
  type        = string
}

variable "hourly_budget_usd" {
  description = "時間あたり推論コスト上限 (USD): この値を超えると Bedrock に強制切り替え + Chatwork 通知"
  type        = number
  default     = 1.0
}

variable "lambda_reserved_concurrency" {
  description = "コストアラート Lambda の予約同時実行数: 突発的なアラームスパイクでも過剰実行を防ぐ"
  type        = number
  default     = 5
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
