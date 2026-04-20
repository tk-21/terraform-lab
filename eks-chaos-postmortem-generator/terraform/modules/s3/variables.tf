# =============================================================================
# S3モジュール 変数定義
# =============================================================================

variable "project" {
  description = "プロジェクト名（バケット名のプレフィックスに使用）"
  type        = string
}

variable "environment" {
  description = "環境名（dev / stg / prod）"
  type        = string
}

variable "aws_account_id" {
  description = "AWSアカウントID（グローバル一意なバケット名の生成に使用）"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
}
