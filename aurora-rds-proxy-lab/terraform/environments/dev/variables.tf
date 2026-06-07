variable "aws_region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "リソース名プレフィックス（IAMロール名64文字制限対応）"
  type        = string
  default     = "arpl"
}

variable "vpc_cidr" {
  description = "VPC CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "chatwork_room_id" {
  description = "Chatwork 通知先ルームID（機密値のため tfvars に書かない）"
  type        = string
}

variable "ecr_image_uri" {
  description = "ECS にデプロイする Docker イメージ URI（初回は空文字 → ECR リポジトリ URL:latest で代替）"
  type        = string
  default     = ""
}

variable "github_org" {
  description = "GitHub Organization 名（OIDC ロールの Condition 設定用）"
  type        = string
  default     = "takuya"
}

variable "github_repo" {
  description = "GitHub リポジトリ名（OIDC ロールの Condition 設定用）"
  type        = string
  default     = "aurora-rds-proxy-lab"
}
