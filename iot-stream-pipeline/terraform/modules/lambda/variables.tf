variable "project_name" {
  description = "全リソースに付与するプロジェクト名プレフィックス"
  type        = string
}

variable "processor_image_uri" {
  description = "processorLambdaのECRイメージURI"
  type        = string
}

variable "reader_image_uri" {
  description = "readerLambdaのECRイメージURI"
  type        = string
}

variable "dynamodb_table_name" {
  description = "センサーデータ保存先DynamoDBテーブル名"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "センサーデータ保存先DynamoDBテーブルARN (IAMポリシーで使用)"
  type        = string
}

variable "kinesis_stream_arn" {
  description = "イベントトリガー元KinesisストリームARN"
  type        = string
}
