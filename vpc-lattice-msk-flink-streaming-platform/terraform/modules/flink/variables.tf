variable "name_prefix" {
  description = "リソース命名プレフィックス"
  type        = string
}

variable "flink_role_arn" {
  description = "Flink実行IAMロールARN"
  type        = string
}

variable "flink_app_bucket_arn" {
  description = "FlinkアプリJAR格納S3バケットARN"
  type        = string
}

variable "flink_app_bucket_name" {
  description = "FlinkアプリJAR格納S3バケット名"
  type        = string
}

variable "output_bucket_name" {
  description = "Flinkイベント出力S3バケット名"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK Serverless SASL/IAM認証ブートストラップブローカー"
  type        = string
}

variable "private_subnet_ids" {
  description = "プライベートサブネットIDリスト"
  type        = list(string)
}

variable "sg_flink_id" {
  description = "Flink用セキュリティグループID"
  type        = string
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
