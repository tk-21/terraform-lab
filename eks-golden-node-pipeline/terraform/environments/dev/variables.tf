variable "project" {
  type    = string
  default = "eks-golden-node-pipeline"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "eks_version" {
  type    = string
  default = "1.30"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "karpenter_version" {
  type    = string
  default = "0.37.0"
}

variable "golden_ami_id" {
  description = "Golden AMI の AMI ID。空の場合は名前フィルタで最新版を自動選択"
  type        = string
  default     = ""
}
