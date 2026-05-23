variable "aws_region" {
  description = "デプロイ先AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "env" {
  description = "環境名（dev/stg/prod）"
  type        = string
  default     = "dev"
}

variable "aws_account_id" {
  description = "AWSアカウントID（S3バケット名の一意性確保に使用）"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID（既存VPCを利用する場合）"
  type        = string
}

variable "private_subnet_ids" {
  description = "ECS/Lambda用プライベートサブネットIDリスト"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック（VPC Endpointのセキュリティグループに使用）"
  type        = string
  default     = "10.0.0.0/16"
}

variable "chatwork_room_id" {
  description = "Chatwork通知先ルームID"
  type        = string
}
