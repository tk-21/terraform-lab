variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "cluster_name" {
  description = "EKSクラスタ名（サブネットタグに使用）"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック"
  type        = string
  default     = "10.0.0.0/16"
}
