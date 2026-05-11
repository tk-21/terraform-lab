variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID (ECR リポジトリポリシーで使用)"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
