variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "aws_account_id" {
  description = "AWSアカウントID (バケット名のサフィックスに使用)"
  type        = string
}
