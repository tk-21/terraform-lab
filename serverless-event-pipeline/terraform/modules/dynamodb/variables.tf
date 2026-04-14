# dynamodb モジュールの変数定義

variable "project" {
  description = "プロジェクト識別子（sep）。リソース命名の prefix に使用する。"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名（dev / staging / prod）。"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment は dev / staging / prod のいずれかを指定してください。"
  }
}

variable "enable_pitr" {
  description = <<-EOT
    PITR（ポイントインタイムリカバリ）を有効化するか。
    本番環境のみ true を指定する。dev / staging では false でコストを管理する。
  EOT
  type        = bool
  default     = false
}

variable "common_tags" {
  description = "リソースに付与する追加タグ。provider の default_tags とマージされる。"
  type        = map(string)
  default     = {}
}
