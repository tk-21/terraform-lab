# =============================================================================
# Lambdaモジュール 変数定義
# =============================================================================

variable "project" {
  description = "プロジェクト名（全リソースの命名プレフィックスに使用）"
  type        = string
}

variable "environment" {
  description = "環境名（dev / stg / prod）"
  type        = string
}

variable "aws_account_id" {
  description = "AWSアカウントID（S3バケット名やIAMポリシーのARN組み立てに使用）"
  type        = string
}

variable "region" {
  description = "デプロイ先AWSリージョン（Lambda Powertoolsレイヤーのリージョン指定に使用）"
  type        = string
  default     = "ap-northeast-1"
}

variable "step_functions_arn" {
  description = "ポストモーテムワークフローのStep Functions ARN（Phase 3で設定、空文字の場合はStep Functions起動をスキップ）"
  type        = string
  default     = ""
}

variable "s3_bucket_arn" {
  description = "レポート保存S3バケットのARN（report-formatter LambdaのIAMポリシーに使用）"
  type        = string
  default     = ""
}

variable "s3_bucket_name" {
  description = "レポート保存S3バケット名（report-formatter Lambda環境変数に設定）"
  type        = string
  default     = ""
}

variable "eks_cluster_name" {
  description = "EKSクラスター名（data-collectorがK8s APIへアクセスするために使用）"
  type        = string
  default     = ""
}

variable "eks_cluster_endpoint" {
  description = "EKSクラスターAPIエンドポイント（data-collector環境変数に設定）"
  type        = string
  default     = ""
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
}
