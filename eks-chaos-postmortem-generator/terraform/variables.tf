# =============================================================================
# Terraform変数定義 - EKS Chaos Postmortem Generator
# =============================================================================

variable "project" {
  description = "プロジェクト名（全リソースの命名プレフィックスに使用）"
  type        = string
  default     = "eks-chaos-postmortem-generator"
}

variable "environment" {
  description = "環境名（dev/stg/prod）- リソース命名とタグに使用"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWSリージョン（デフォルト: 東京リージョン）"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_account_id" {
  description = "AWSアカウントID（IAMポリシーのARN構築に使用）"
  type        = string
}
