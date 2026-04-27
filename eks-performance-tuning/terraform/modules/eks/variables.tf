variable "cluster_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for the node group"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for the cluster endpoint"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "0.36.3"
}
