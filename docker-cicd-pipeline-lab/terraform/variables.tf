variable "aws_region" {
  description = "デプロイ先 AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "プロジェクト名 (リソース命名に使用)"
  type        = string
  default     = "cicd-lab"
}

variable "environment" {
  description = "環境名"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "VPC の CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "使用するアベイラビリティゾーン"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "github_connection_arn" {
  description = "CodeStar Connections の GitHub Connection ARN"
  type        = string
}

variable "github_owner" {
  description = "GitHub リポジトリオーナー名"
  type        = string
}

variable "github_repo" {
  description = "GitHub リポジトリ名"
  type        = string
}

variable "github_branch" {
  description = "監視するブランチ名"
  type        = string
  default     = "main"
}
