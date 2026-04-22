variable "name_prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "lambda_role_arn" {
  description = "Lambda ProducerのIAMロールARN"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK Serverless SASL/IAM接続エンドポイント"
  type        = string
}

variable "subnet_ids" {
  description = "LambdaのVPC設定用プライベートサブネットIDリスト"
  type        = list(string)
}

variable "sg_lambda_id" {
  description = "Lambda用セキュリティグループID"
  type        = string
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
