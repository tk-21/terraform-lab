variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "db_subnet_ids" {
  description = "DB サブネット ID リスト（RDS Proxy 配置用）"
  type        = list(string)
}

variable "aurora_sg_id" {
  description = "Aurora クラスターのセキュリティグループ ID"
  type        = string
}

variable "cluster_id" {
  description = "Aurora クラスター識別子"
  type        = string
}

variable "cluster_endpoint" {
  description = "Aurora Writer エンドポイント"
  type        = string
}

variable "reader_endpoint" {
  description = "Aurora Reader エンドポイント"
  type        = string
}

variable "master_secret_arn" {
  description = "マスターユーザー認証情報の Secrets Manager ARN"
  type        = string
}

variable "db_master_username" {
  description = "Aurora マスターユーザー名"
  type        = string
}

variable "aws_region" {
  description = "AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_account_id" {
  description = "AWS アカウント ID（IAM ポリシーの Resource ARN 生成に使用）"
  type        = string
}
