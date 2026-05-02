variable "aws_region" {
  description = "AWSリージョン"
  default     = "ap-northeast-1"
}

variable "project" {
  description = "プロジェクト識別子（命名規則のプレフィックス）"
  default     = "handson"
}

variable "environment" {
  description = "環境識別子"
  default     = "dev"
}
