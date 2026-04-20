# =============================================================================
# FISモジュール 変数定義
# =============================================================================

variable "project" {
  description = "プロジェクト名（全リソースの命名プレフィックスに使用）"
  type        = string
}

variable "environment" {
  description = "環境名（dev / stg / prod）"
  type        = string
}

variable "cluster_name" {
  description = "FIS実験対象のEKSクラスター名"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ（Project, Environment, ManagedBy, Owner, CostCenter）"
  type        = map(string)
}
