variable "name_prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "subnet_ids" {
  description = "MSKを配置するプライベートサブネットIDリスト（2つ以上）"
  type        = list(string)
}

variable "sg_msk_id" {
  description = "MSK用セキュリティグループID"
  type        = string
}

variable "lambda_role_arn" {
  description = "Lambda ProducerロールのARN（MSKクラスターポリシーで許可するロール）"
  type        = string
}

variable "flink_role_arn" {
  description = "FlinkロールのARN（MSKクラスターポリシーで許可するロール）"
  type        = string
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
