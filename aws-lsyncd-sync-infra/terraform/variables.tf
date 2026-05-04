# =============================================================
# variables.tf — 変数定義
# =============================================================

variable "aws_region" {
  description = "デプロイ先 AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "環境識別子"
  type        = string
  default     = "handson"
}

variable "project_name" {
  description = "リソース名プレフィックス（IAM ロール名 64 文字制限に注意）"
  type        = string
  default     = "lsyncd-ws"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "instance_type" {
  description = "EC2 インスタンスタイプ（コスト最小化）"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "Amazon Linux 2023 AMI (ap-northeast-1)"
  type        = string
  # 最新確認: aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
  default = "ami-0599b6e53ca798bb2"
}

variable "slave_count" {
  description = "slave EC2 台数"
  type        = number
  default     = 2
}
