variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  description = "EKS クラスター名"
  type        = string
}

variable "cluster_version" {
  description = "EKS バージョン"
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "EKS ノード配置サブネット"
  type        = list(string)
}

variable "intra_subnet_ids" {
  description = "EKS Control Plane ENI 配置サブネット"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
