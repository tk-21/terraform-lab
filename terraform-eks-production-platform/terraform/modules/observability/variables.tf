################################################################################
# Observabilityモジュール - 変数定義
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

variable "oidc_provider_arn" {
  description = "EKS OIDC ProviderのARN。IRSA設定に使用"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC ProviderのURL（プロトコルなし）"
  type        = string
}

variable "grafana_admin_user" {
  description = "Amazon Managed GrafanaのSSO管理者ユーザーのメールアドレス"
  type        = string
}

variable "grafana_admin_user_ids" {
  description = "Amazon Managed GrafanaのADMINに関連付けるIAM Identity CenterユーザーIDのリスト。未指定時は関連付けを作成しない"
  type        = list(string)
  default     = []
}
