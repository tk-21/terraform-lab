variable "cluster_name" {
  description = "EKSクラスター名"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS APIサーバーエンドポイント"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "project_name" {
  description = "プロジェクト名（EC2NodeClassタグ用）"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC Provider ARN（IRSA用）"
  type        = string
}

variable "oidc_issuer" {
  description = "EKS OIDC Issuer（https://プレフィックスなし）"
  type        = string
}

variable "node_group_role_arn" {
  description = "Karpenterが起動するNodeに付与するIAMロールARN"
  type        = string
}

variable "node_group_role_name" {
  description = "Karpenterが起動するNodeに付与するIAMロール名"
  type        = string
}

variable "common_tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
