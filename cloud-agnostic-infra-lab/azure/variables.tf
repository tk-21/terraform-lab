variable "subscription_id" {
  description = "AzureサブスクリプションID（AWSのアカウントIDに相当）"
  type        = string
}

variable "location" {
  description = "Azureリージョン（Locationと呼ぶ点がAWS/GCPと異なる）"
  type        = string
  default     = "japanwest"
}

variable "project" {
  description = "プロジェクト識別子"
  type        = string
  default     = "cail"
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}

variable "ssh_public_key" {
  description = "SSH公開鍵（VMSSのadmin_ssh_keyに使用）"
  type        = string
}
