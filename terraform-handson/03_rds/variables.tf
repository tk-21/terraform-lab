variable "aws_region" {
  description = "デプロイ先の AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
  default     = "handson"
}

# ── 01_vpc から受け取る値 ──────────────────────────────────
variable "vpc_id" {
  description = "配置先 VPC ID（01_vpc: terraform output -raw vpc_id）"
  type        = string
}

variable "private_subnet_ids" {
  description = "RDS 配置先プライベートサブネット ID リスト（01_vpc: terraform output -json private_subnet_ids）"
  type        = list(string)
}

# ── 02_ec2 から受け取る値 ──────────────────────────────────
variable "ec2_security_group_id" {
  description = "EC2 の SG ID（02_ec2: terraform output -raw security_group_id）MySQL 接続許可に使用"
  type        = string
}

# ── DB 設定 ───────────────────────────────────────────────
variable "db_name" {
  description = "初期データベース名"
  type        = string
  default     = "handsondb"
}

variable "db_username" {
  description = "DB 管理ユーザー名"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "DB パスワード（8文字以上）。terraform.tfvars に定義して Git に含めないこと"
  type        = string
  sensitive   = true # terraform plan/apply の出力でマスクされる
}
