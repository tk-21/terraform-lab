variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "env" {
  description = "環境識別子"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "KarpenterをインストールするEKSクラスタ名"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS APIサーバーのエンドポイント"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDCプロバイダーのARN (KarpenterのIRSAに使用)"
  type        = string
}

variable "node_role_arn" {
  description = "EKSノード用IAMロールARN (Karpenter EC2NodeClassで指定)"
  type        = string
}

variable "karpenter_version" {
  description = "KarpenterのHelmチャートバージョン"
  type        = string
  default     = "0.37.0"
}

variable "gpu_nodepool_name" {
  description = "GPU推論用KarpenterNodePoolの名前 (AIInferenceServiceのgpuNodePoolRefと一致させる)"
  type        = string
  default     = "karpenter-gpu-g5g"
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
