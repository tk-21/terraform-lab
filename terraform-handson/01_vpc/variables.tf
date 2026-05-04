# =============================================================
# 変数定義
# 【学習ポイント】
#   - description で変数の意味を明示する
#   - default を設定することで -var なしでも動作する
#   - type を明示することで不正な値を早期に検出できる
# =============================================================

variable "aws_region" {
  description = "デプロイ先の AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "全リソース名に付けるプレフィックス（環境を識別するために使う）"
  type        = string
  default     = "handson"
}

variable "vpc_cidr" {
  description = "VPC の CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "パブリックサブネットの CIDR リスト（AZ 数と一致させること）"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネットの CIDR リスト（AZ 数と一致させること）"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}
