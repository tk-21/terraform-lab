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
  description = "AWS アカウント ID"
  type        = string
}

variable "vpc_id" {
  description = "ECS / ALB を配置する VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB 配置用パブリックサブネット ID リスト"
  type        = list(string)
}

variable "private_app_subnet_ids" {
  description = "ECS Fargate 配置用プライベートサブネット ID リスト"
  type        = list(string)
}

variable "proxy_sg_id" {
  description = "RDS Proxy セキュリティグループ ID（アプリ SG の Egress 設定に使用）"
  type        = string
}

variable "vpc_endpoint_sg_id" {
  description = "VPC Endpoint セキュリティグループ ID（SSM/ECR/CloudWatch Logs 通信許可）"
  type        = string
}

variable "app_rds_connect_policy_arn" {
  description = "ECS Task Role にアタッチする RDS Proxy 接続ポリシー ARN"
  type        = string
}

variable "ecr_image_uri" {
  description = "デプロイする Docker イメージ URI（初回は空文字→ECRリポジトリURL:latest で代替）"
  type        = string
  default     = ""
}

variable "github_org" {
  description = "GitHub Organization 名（OIDC ロールの条件設定用）"
  type        = string
}

variable "github_repo" {
  description = "GitHub リポジトリ名（OIDC ロールの条件設定用）"
  type        = string
}
