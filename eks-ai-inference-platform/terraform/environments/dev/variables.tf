variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "プロジェクト識別子"
  type        = string
  default     = "eks-ai-inf"
}

variable "environment" {
  description = "環境名"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_version" {
  description = "EKSクラスターバージョン"
  type        = string
  default     = "1.30"
}

variable "node_instance_type" {
  description = "システムMNGインスタンスタイプ"
  type        = string
  default     = "c7g.medium"
}
