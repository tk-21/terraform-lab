variable "name_prefix" {
  description = "リソース命名プレフィックス"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "sg_vpc_lattice_id" {
  description = "VPC Lattice用セキュリティグループID"
  type        = string
}

variable "lambda_role_arn" {
  description = "Lambda ProducerのIAMロールARN"
  type        = string
}

variable "flink_role_arn" {
  description = "FlinkのIAMロールARN"
  type        = string
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
