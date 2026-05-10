variable "project" {
  description = "プロジェクト名"
  type        = string
  default     = "chaos-engineering-lab"
}

variable "prefix" {
  description = "リソース名プレフィックス（例: cel）"
  type        = string
  default     = "cel"
  validation {
    condition     = length(var.prefix) <= 5
    error_message = "プレフィックスは 5 文字以内にしてください（IAM ロール名 64 文字制限のため）"
  }
}

variable "env" {
  description = "環境名（例: dev / stg / prod）"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "account_id" {
  description = "AWS アカウント ID（S3 バックエンドバケット名・ALB ログバケットポリシーで使用）"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "VPC の CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "パブリックサブネットの CIDR リスト"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネットの CIDR リスト"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "availability_zones" {
  description = "使用するアベイラビリティゾーンのリスト"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

# ── Phase 2: ASG スケーリング設定 ──────────────────────────────────

variable "asg_min_size" {
  description = "ASG の最小インスタンス数"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "ASG の最大インスタンス数"
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "ASG の希望インスタンス数"
  type        = number
  default     = 2
}
