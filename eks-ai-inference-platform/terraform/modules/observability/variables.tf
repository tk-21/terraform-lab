variable "project" {
  description = "プロジェクト識別子"
  type        = string
}

variable "environment" {
  description = "環境名 (dev / stg / prod)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDCプロバイダーARN (OTEL Collector IRSA用)"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDCプロバイダーURL (OTEL Collector IRSA用)"
  type        = string
}
