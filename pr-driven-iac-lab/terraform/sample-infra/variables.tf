variable "environment" {
  description = "デプロイ環境名（dev/stg/prod）。S3バケット名・IAMロール名に使用"
  type        = string
  default     = "dev"
}
