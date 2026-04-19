variable "cluster_name" {
  description = "EKS クラスター名"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS クラスターエンドポイント"
  type        = string
}

variable "karpenter_version" {
  description = "Karpenter Helm チャートバージョン"
  type        = string
  default     = "0.37.0"
}

variable "karpenter_irsa_arn" {
  description = "Karpenter Controller の IRSA ARN（Phase 4 の EKS モジュール出力）"
  type        = string
}

variable "karpenter_node_instance_profile_name" {
  description = "Karpenter ノードの Instance Profile 名（Phase 4 の EKS モジュール出力）"
  type        = string
}

variable "karpenter_node_role_arn" {
  description = "Karpenter ノードの IAM Role ARN"
  type        = string
}

variable "private_subnet_ids" {
  description = "ノードを配置するプライベートサブネット ID リスト"
  type        = list(string)
}

variable "golden_ami_id" {
  description = "Phase 3 でビルドした Golden AMI の AMI ID。空文字の場合は AMI 名フィルタで検索"
  type        = string
  default     = ""
}

variable "eks_version" {
  description = "EKS バージョン（AMI 名フィルタで使用）"
  type        = string
  default     = "1.30"
}

variable "tags" {
  type    = map(string)
  default = {}
}
