# =============================================================================
# EKSモジュール変数定義
# =============================================================================

variable "project" {
  description = "プロジェクト名（リソース命名に使用）"
  type        = string
}

variable "environment" {
  description = "環境名（dev/stg/prod）"
  type        = string
}

variable "cluster_name" {
  description = "EKSクラスター名"
  type        = string
}

variable "vpc_id" {
  description = "EKSクラスターを配置するVPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "EKSノードグループを配置するプライベートサブネットIDリスト"
  type        = list(string)
}

variable "aws_account_id" {
  description = "AWSアカウントID（IAMポリシーのARN構築に使用）"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
