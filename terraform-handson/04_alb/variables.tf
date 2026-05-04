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

variable "public_subnet_ids" {
  description = "ALB と ASG を配置するパブリックサブネット ID リスト（01_vpc: terraform output -json public_subnet_ids）"
  type        = list(string)
}

# ── ASG 設定 ──────────────────────────────────────────────
variable "asg_min_size" {
  description = "ASG 最小インスタンス数"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "ASG 最大インスタンス数"
  type        = number
  default     = 3
}

variable "asg_desired_capacity" {
  description = "ASG 希望インスタンス数（起動直後の台数）"
  type        = number
  default     = 2
}
