variable "prefix" {
  description = "リソース名のプレフィックス"
  type        = string
}

variable "account_id" {
  description = "AWSアカウントID"
  type        = string
}

variable "region" {
  description = "AWSリージョン"
  type        = string
}

variable "common_tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
}

variable "artifacts_bucket_name" {
  description = "LambdaコードZIP格納用S3バケット名"
  type        = string
}

variable "codepipeline_arn" {
  description = "デプロイ用CodePipelineのARN（endpointモジュール出力）"
  type        = string
}

variable "eventbridge_codepipeline_role_arn" {
  description = "EventBridgeがCodePipelineを起動するIAMロールのARN（endpointモジュール出力）"
  type        = string
}

variable "powertools_layer_version" {
  description = "AWS Lambda Powertools managed layerのバージョン（arm64）"
  type        = number
  default     = 79
}
