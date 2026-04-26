variable "environment" {
  description = "デプロイ環境名"
  type        = string
}

variable "lambda_role_arn" {
  description = "bedrock-analyzer LambdaのIAMロールARN（Phase1で作成済み）"
  type        = string
}

variable "reports_bucket" {
  description = "分析レポートを保存するS3バケット名"
  type        = string
}

variable "bedrock_region" {
  description = "Bedrockを呼び出すリージョン（Claude Sonnetが使えるリージョン）"
  type        = string
  default     = "us-east-1"
}

variable "log_group_name" {
  description = "CloudWatch Logsグループ名（Phase1で作成済み）"
  type        = string
}

variable "tags" {
  description = "リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
