variable "project_id" {
  description = "GCPプロジェクトID（AWSのアカウントIDに相当）"
  type        = string
}

variable "region" {
  description = "GCPリージョン"
  type        = string
  default     = "asia-northeast1" # 東京
}

variable "project" {
  description = "プロジェクト識別子（ラベル・リソース名に使用）"
  type        = string
  default     = "cail"
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}
