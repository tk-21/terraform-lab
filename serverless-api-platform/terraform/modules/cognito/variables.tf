# terraform/modules/cognito/variables.tf

variable "prefix" {
  description = "リソース名のプレフィックス。例: sap-dev"
  type        = string
}

variable "environment" {
  description = "デプロイ環境名。タグや設定の切り替えに使用する。"
  type        = string
}

variable "enable_deletion_protection" {
  description = <<-EOT
    Cognito User Pool の削除保護を有効化する。
    prod では true（ACTIVE）にして誤削除を防止する。
    dev では false（INACTIVE）にして terraform destroy を容易にする。
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "全リソースに付与するタグ。environments/ の common_tags を渡す。"
  type        = map(string)
  default     = {}
}
