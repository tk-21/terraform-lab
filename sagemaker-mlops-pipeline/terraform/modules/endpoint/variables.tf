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
  description = "アーティファクト保存用S3バケット名（CodePipelineアーティファクトストアとして使用）"
  type        = string
}

variable "endpoint_role_arn" {
  description = "SageMaker Endpoint実行ロールのARN"
  type        = string
}

variable "endpoint_instance_type" {
  description = "推論エンドポイントのインスタンスタイプ"
  type        = string
  default     = "ml.t2.medium"
}

variable "endpoint_model_name" {
  description = "初期デプロイ用SageMakerモデル名（初回Pipeline実行後に設定。空文字の場合はEndpointを作成しない）"
  type        = string
  default     = ""
}
