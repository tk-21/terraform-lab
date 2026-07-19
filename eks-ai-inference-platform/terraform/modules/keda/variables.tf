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
  description = "EKS OIDCプロバイダーARN (KEDA IRSA の信頼ポリシーに使用)"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDCプロバイダーURL (ホスト名のみ、https:// なし)"
  type        = string
}

variable "amp_workspace_arn" {
  description = "AMPワークスペースARN (KEDAがAMPをクエリするためのIAMポリシーに使用)"
  type        = string
}

variable "lambda_reserved_concurrency" {
  description = "スケール通知 Lambda の予約同時実行数: EC2イベントスパイク時の過剰実行を防ぐ"
  type        = number
  default     = 3
}
