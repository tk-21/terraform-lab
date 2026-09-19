variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "env" {
  description = "環境識別子"
  type        = string
  default     = "dev"
}

variable "oidc_provider_arn" {
  description = "EKS OIDCプロバイダーのARN"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDCプロバイダーのURL (https://oidc.eks...形式)"
  type        = string
}

variable "operator_namespace" {
  description = "OperatorがデプロイされるKubernetesのNamespace"
  type        = string
  default     = "gpu-inference-operator-system"
}

variable "operator_service_account" {
  description = "OperatorのKubernetes ServiceAccount名"
  type        = string
  default     = "controller-manager"
}

variable "bedrock_model_ids" {
  description = "Bedrockフォールバックで使用するモデルIDリスト"
  type        = list(string)
  default = [
    "anthropic.claude-3-haiku-20240307-v1:0",
    "anthropic.claude-3-sonnet-20240229-v1:0",
  ]
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
