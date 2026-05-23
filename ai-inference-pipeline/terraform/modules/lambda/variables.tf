variable "name_prefix" {
  description = "リソース名プレフィックス（例: aip-dev）"
  type        = string
}

variable "env" {
  description = "環境名（dev/stg/prod）"
  type        = string
}

variable "vpc_id" {
  description = "Lambda VPC配置先のVPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Lambda配置先プライベートサブネットIDリスト"
  type        = list(string)
}

variable "lambda_bedrock_role_arn" {
  description = "Bedrock推論Lambda実行ロールのARN"
  type        = string
}

variable "lambda_notify_role_arn" {
  description = "Chatwork通知Lambda実行ロールのARN"
  type        = string
}

variable "dynamodb_table_name" {
  description = "推論結果保存先DynamoDBテーブル名"
  type        = string
}

variable "output_bucket_name" {
  description = "前処理済みデータが格納されたS3バケット名"
  type        = string
}

variable "chatwork_room_id" {
  description = "Chatwork通知先ルームID"
  type        = string
}
