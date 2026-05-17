variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "environment" {
  description = "環境名"
  type        = string
}

variable "vpc_id" {
  description = "ALB を配置する VPC の ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB を配置する Public サブネット ID マップ (key: AZ suffix)"
  type        = map(string)
}

variable "sg_id" {
  description = "ALB に紐付ける Security Group ID"
  type        = string
}
