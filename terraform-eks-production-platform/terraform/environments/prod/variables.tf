################################################################################
# prod環境 - 変数定義
################################################################################

variable "project_name" {
  description = "プロジェクト名。リソース命名・タグ付けに使用する"
  type        = string
  default     = "terraform-eks-production-platform"
}

variable "environment" {
  description = "環境名"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "eks_public_access_cidrs" {
  description = "EKS APIサーバーへのパブリックアクセスを許可するCIDRリスト。0.0.0.0/0は設定禁止"
  type        = list(string)
}

variable "eks_cluster_version" {
  description = "EKS Kubernetesバージョン"
  type        = string
  default     = "1.29"
}

variable "node_group_instance_types" {
  description = "Managed Node Groupのインスタンスタイプリスト"
  type        = list(string)
  default     = ["t3.medium", "t3.large"]
}

variable "karpenter_version" {
  description = "KarpenterのHelmチャートバージョン"
  type        = string
  default     = "0.35.0"
}

variable "argocd_version" {
  description = "ArgoCDのHelmチャートバージョン"
  type        = string
  default     = "6.7.3"
}

variable "grafana_admin_user" {
  description = "Amazon Managed GrafanaのSSO管理者ユーザーのメールアドレス"
  type        = string
}
