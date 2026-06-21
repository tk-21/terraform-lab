variable "name_prefix" {
  description = "リソース命名プレフィックス"
  type        = string
}

variable "account_id" {
  description = "AWS アカウント ID"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR リポジトリ URL"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR リポジトリ ARN (IAM ポリシーのスコープ限定用)"
  type        = string
}

variable "artifact_bucket_arn" {
  description = "CodePipeline アーティファクト S3 バケット ARN"
  type        = string
}
