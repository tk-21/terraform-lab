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

variable "pipeline_role_arn" {
  description = "SageMaker Monitor Job実行ロールのARN（foundationモジュール出力）"
  type        = string
}

variable "artifacts_bucket_name" {
  description = "アーティファクト保存用S3バケット名"
  type        = string
}

variable "data_bucket_name" {
  description = "学習データ保存用S3バケット名（Ground Truth格納先）"
  type        = string
}

variable "endpoint_name" {
  description = "監視対象のSageMaker Endpoint名"
  type        = string
  default     = ""
}

variable "endpoint_instance_type" {
  description = "Data Captureつきエンドポイント設定のインスタンスタイプ"
  type        = string
  default     = "ml.t2.medium"
}

variable "endpoint_model_name" {
  description = "Data Captureつきエンドポイント設定に使用するSageMakerモデル名。空文字の場合は設定を作成しない"
  type        = string
  default     = ""
}

variable "data_quality_baseline_uri" {
  description = "Data Qualityベースラインが保存されているS3 URI。ベースライン生成スクリプト実行後に設定する"
  type        = string
  default     = ""
}

variable "model_quality_baseline_uri" {
  description = "Model Qualityベースラインが保存されているS3 URI。ベースライン生成スクリプト実行後に設定する"
  type        = string
  default     = ""
}

variable "powertools_layer_version" {
  description = "AWS Lambda Powertools managed layerのバージョン（arm64）"
  type        = number
  default     = 79
}
