variable "name_prefix" {
  description = "リソース命名プレフィックス（例: handson-dev）"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_id" {
  description = "VPC ID（vpcモジュールのoutputから取得）"
  type        = string
}

variable "private_subnet_ids" {
  description = "EC2を配置するプライベートサブネットIDリスト"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2インスタンスタイプ"
  type        = string
  default     = "t3.micro"
}
