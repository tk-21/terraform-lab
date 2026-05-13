variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "eks_cluster_version" {
  description = "EKS Kubernetesバージョン"
  type        = string
}

variable "node_instance_type" {
  description = "ワーカーノードEC2インスタンスタイプ"
  type        = string
}

variable "node_desired_size" {
  description = "ワーカーノード希望台数"
  type        = number
}

variable "node_min_size" {
  description = "ワーカーノード最小台数"
  type        = number
}

variable "node_max_size" {
  description = "ワーカーノード最大台数"
  type        = number
}

variable "allowed_cidr_blocks" {
  description = "EKS APIエンドポイントへのアクセス許可CIDR"
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "EKSクラスタIAMロールARN"
  type        = string
}

variable "node_role_arn" {
  description = "EKSワーカーノードIAMロールARN"
  type        = string
}

variable "private_subnet_ids" {
  description = "EKSワーカーノードを配置するプライベートサブネットIDリスト"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "パブリックサブネットIDリスト（EKSサービス用）"
  type        = list(string)
}
