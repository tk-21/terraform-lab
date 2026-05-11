variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "vpc_id" {
  description = "ALB / ターゲットグループを作成する VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB を配置するパブリックサブネット ID リスト"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "ALB に適用するセキュリティグループ ID"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
