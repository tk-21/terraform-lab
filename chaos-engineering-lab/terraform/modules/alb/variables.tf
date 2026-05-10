variable "vpc_id" {
  description = "ALB を配置する VPC の ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB を配置するパブリックサブネット ID のリスト"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "ALB に適用するセキュリティグループの ID"
  type        = string
}

variable "prefix" {
  description = "リソース名プレフィックス（例: cel）"
  type        = string
}

variable "env" {
  description = "環境名（例: dev）"
  type        = string
}

variable "account_id" {
  description = "AWS アカウント ID（S3 バケット名・バケットポリシーで使用）"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
