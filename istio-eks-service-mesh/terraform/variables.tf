variable "project_name" {
  description = "プロジェクト名（リソース命名に使用）"
  type        = string
  default     = "istio-eks-service-mesh"
}

variable "env" {
  description = "環境名（dev / stg / prod）"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "eks_cluster_version" {
  description = "EKS Kubernetesバージョン"
  type        = string
  default     = "1.29"
}

variable "node_instance_type" {
  description = "ワーカーノードのEC2インスタンスタイプ"
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "ワーカーノードの希望台数"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "ワーカーノードの最小台数"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "ワーカーノードの最大台数"
  type        = number
  default     = 3
}

variable "allowed_cidr_blocks" {
  description = "EKS APIエンドポイントへのアクセス許可CIDR（自分のIPを設定）"
  type        = list(string)
}

variable "report_bucket_lifecycle_days" {
  description = "S3レポートバケットのオブジェクト有効期限（日）"
  type        = number
  default     = 30
}

variable "github_org" {
  description = "GitHub OrganizationまたはユーザーID（OIDC認証用）"
  type        = string
  default     = "YOUR_GITHUB_ORG"
}
