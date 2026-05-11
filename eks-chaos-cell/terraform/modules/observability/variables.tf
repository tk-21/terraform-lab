variable "cluster_name" {
  description = "EKSクラスター名（リソース命名に使用）"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "oidc_provider_arn" {
  description = "EKS OIDCプロバイダーのARN（IRSA用）"
  type        = string
}

variable "oidc_issuer" {
  description = "EKS OIDCイシュアー（https://なし）"
  type        = string
}

variable "common_tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
