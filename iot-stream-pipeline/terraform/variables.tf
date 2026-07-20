variable "aws_region" {
  description = "デプロイ先AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "全リソースに付与するプロジェクト名プレフィックス"
  type        = string
  default     = "iot-pipeline"
}

variable "processor_image_uri" {
  description = "processorLambdaのECRイメージURI"
  type        = string
}

variable "reader_image_uri" {
  description = "readerLambdaのECRイメージURI"
  type        = string
}
