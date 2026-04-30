variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "pipeline_role_arn" {
  description = "SageMaker Pipeline実行ロールのARN"
  type        = string
}

variable "common_tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
}
