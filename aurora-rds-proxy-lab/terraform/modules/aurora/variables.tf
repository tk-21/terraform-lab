variable "prefix" {
  description = "リソース名プレフィックス（IAMロール名64文字制限対応）"
  type        = string
}

variable "vpc_id" {
  description = "Aurora を配置する VPC ID"
  type        = string
}

variable "db_subnet_ids" {
  description = "Aurora 用プライベート DB サブネット ID リスト"
  type        = list(string)
}

variable "app_sg_id" {
  description = "後方互換のため残存（未使用: インバウンドルールは rds-proxy/rotation モジュールが aws_security_group_rule で管理）"
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "db_name" {
  description = "初期データベース名"
  type        = string
  default     = "appdb"
}

variable "db_master_username" {
  description = "マスターユーザー名"
  type        = string
  default     = "dbadmin"
}

variable "min_acu" {
  description = "Serverless v2 最小キャパシティ（ACU）"
  type        = number
  default     = 0.5
}

variable "max_acu" {
  description = "Serverless v2 最大キャパシティ（ACU）"
  type        = number
  default     = 4
}
