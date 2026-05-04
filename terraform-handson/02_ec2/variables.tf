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

variable "public_subnet_id" {
  description = "配置先パブリックサブネット ID（01_vpc: terraform output -json public_subnet_ids | jq -r '.[0]'）"
  type        = string
}

# ── EC2 設定 ──────────────────────────────────────────────
variable "instance_type" {
  description = "EC2 インスタンスタイプ（コスト最小: t3.micro）"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "SSH キーペア名（空文字の場合はキーペアなしで起動）"
  type        = string
  default     = ""
}

variable "ssh_allowed_cidr" {
  description = "SSH を許可する CIDR（本番では自分のIPに絞ること: x.x.x.x/32）"
  type        = string
  default     = "0.0.0.0/0"
}
