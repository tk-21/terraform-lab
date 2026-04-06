################################################################################
# Addonsモジュール - 変数定義
################################################################################

variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "環境名"
  type        = string
}

variable "common_tags" {
  description = "すべてのリソースに付与する共通タグ"
  type        = map(string)
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
}

variable "cluster_name" {
  description = "EKSクラスター名"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS APIサーバーのエンドポイントURL"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "EKSクラスターのCA証明書データ"
  type        = string
}

variable "vpc_id" {
  description = "VPCのID"
  type        = string
}

variable "lbc_irsa_role_arn" {
  description = "AWS Load Balancer Controller用IRSAロールのARN"
  type        = string
}

variable "karpenter_irsa_role_arn" {
  description = "Karpenter用IRSAロールのARN"
  type        = string
}

variable "karpenter_sqs_queue_name" {
  description = "Karpenterスポット中断処理用SQSキュー名"
  type        = string
}

variable "karpenter_node_instance_profile_name" {
  description = "KarpenterノードのInstance Profile名"
  type        = string
}

variable "argocd_irsa_role_arn" {
  description = "ArgoCD用IRSAロールのARN"
  type        = string
}

# Karpenterバージョンを変数化する理由：
# Karpenterはアップデート頻度が高く、EKSバージョンとの互換性に注意が必要。
# バージョンを変数化することで環境ごとに検証済みのバージョンを指定できる。
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
