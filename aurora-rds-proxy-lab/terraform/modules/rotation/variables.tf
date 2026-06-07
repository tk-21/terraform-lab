variable "prefix" {
  description = "リソース名プレフィックス（IAMロール名64文字制限対応）"
  type        = string
}

variable "aws_region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_account_id" {
  description = "AWSアカウントID（IAMポリシーのResource ARN構築に使用）"
  type        = string
}

variable "aurora_sg_id" {
  description = "Aurora セキュリティグループID（ローテーション Lambda からのイングレスを許可）"
  type        = string
}

variable "master_secret_arn" {
  description = "Aurora マスターユーザーの Secrets Manager ARN（ローテーション Lambda がパスワード変更に使用）"
  type        = string
}

variable "cluster_endpoint" {
  description = "Aurora Writer エンドポイント（ローテーション Lambda が直接接続）"
  type        = string
}

variable "cluster_id" {
  description = "Aurora クラスター識別子（参照用）"
  type        = string
}

variable "chatwork_room_id" {
  description = "Chatwork 通知先ルームID"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID（ローテーション Lambda の SG 作成に使用）"
  type        = string
}

variable "private_app_subnet_ids" {
  description = "ローテーション Lambda を配置するサブネット ID リスト"
  type        = list(string)
}

variable "vpc_endpoint_sg_id" {
  description = "VPC Endpoint SG ID（Lambda から SecretsManager / SSM への HTTPS 通信を許可）"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR（SG ルールの Egress 範囲）"
  type        = string
}
