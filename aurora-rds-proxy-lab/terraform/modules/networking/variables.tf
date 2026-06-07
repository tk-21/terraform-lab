variable "prefix" {
  description = "リソース名プレフィックス（例: arpl）"
  type        = string
  validation {
    condition     = length(var.prefix) <= 5
    error_message = "プレフィックスは5文字以内にしてください（IAMロール名64文字制限のため）"
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "aws_region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}
