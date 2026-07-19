variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "karpenter_controller_irsa_arn" {
  description = "KarpenterコントローラーのIRSAロールARN (ServiceAccountアノテーションに設定)"
  type        = string
}

variable "karpenter_queue_arn" {
  type = string
}

variable "karpenter_queue_url" {
  type = string
}
