variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "env" {
  description = "環境識別子 (dev / stg / prod)"
  type        = string
  default     = "dev"
}

variable "cluster_version" {
  description = "EKSクラスタのKubernetesバージョン"
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  description = "EKSクラスタを配置するVPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "EKSノードグループ・コントロールプレーンを配置するプライベートサブネットIDリスト"
  type        = list(string)
}

variable "system_node_instance_types" {
  description = "システムコンポーネント用マネージドノードグループのインスタンスタイプ (Graviton2/arm64統一)"
  type        = list(string)
  # t4g.medium: Graviton2, arm64, コスト最適。system-componentsには2vCPU/4GBで十分
  default = ["t4g.medium"]
}

variable "system_node_desired" {
  description = "システムノードグループの希望ノード数"
  type        = number
  default     = 2
}

variable "system_node_min" {
  description = "システムノードグループの最小ノード数"
  type        = number
  default     = 2
}

variable "system_node_max" {
  description = "システムノードグループの最大ノード数"
  type        = number
  default     = 4
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
