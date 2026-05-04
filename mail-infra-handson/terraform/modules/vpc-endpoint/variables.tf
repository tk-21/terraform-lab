variable "aws_region" {
  description = "AWSリージョン。SES SMTPエンドポイントのサービス名に使用する"
  type        = string
  default     = "ap-northeast-1"
}

variable "ec2_iam_role_arn" {
  description = "EC2のIAMロールARN。VPCエンドポイントポリシーで送信元を制限する。空の場合はポリシー制限なし"
  type        = string
  default     = ""
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
