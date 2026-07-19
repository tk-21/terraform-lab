variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "cluster_version" {
  type = string
}

variable "node_instance_type" {
  type = string
}

variable "s3_vpc_endpoint_id" {
  description = "S3 Gateway Endpoint ID (モデルキャッシュバケットポリシーでVPC外アクセスを拒否するため)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック (EKS APIエンドポイントへのアクセス元制限に使用)"
  type        = string
}
