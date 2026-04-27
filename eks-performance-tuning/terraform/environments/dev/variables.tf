variable "environment" {
  description = "Deployment environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ap-northeast-1"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.30"
}

variable "karpenter_version" {
  description = "Helm chart version for Karpenter node autoprovisioner"
  type        = string
  default     = "0.36.3"
}
