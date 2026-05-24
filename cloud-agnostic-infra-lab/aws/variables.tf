variable "region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "プロジェクト識別子（タグ・リソース名に使用）"
  type        = string
  default     = "cail" # cloud-agnostic-infra-lab
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}
