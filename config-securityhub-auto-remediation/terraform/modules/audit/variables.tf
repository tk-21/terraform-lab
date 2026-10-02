variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "aws_account_id" {
  description = "AWSアカウントID (バケット名のサフィックスに使用)"
  type        = string
}

variable "force_destroy" {
  description = "trueの場合、バケットに全バージョンが残っていてもdestroyで削除する (検証環境用)"
  type        = bool
  default     = false
}
