# =============================================================================
# VPCモジュール変数定義
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
  description = "EKSクラスター名（サブネットにEKS用タグを付与するために使用）"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ（プロジェクト・環境・オーナー情報など）"
  type        = map(string)
  default     = {}
}
