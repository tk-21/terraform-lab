variable "project" {
  description = "プロジェクトプレフィックス"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR ブロック"
  type        = string
}

variable "container_image" {
  description = "オリジンコンテナイメージ"
  type        = string
}

variable "domain_name" {
  description = "ACM 証明書発行対象のドメイン名"
  type        = string
}
