variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "リソース名プレフィックス (例: idp)"
  type        = string
  validation {
    condition     = length(var.prefix) <= 5
    error_message = "プレフィックスは5文字以内 (IAMロール名64文字制限のため)"
  }
}

variable "env" {
  description = "環境名 (lab / dev / prod)"
  type        = string
  default     = "lab"
}

variable "bucket_prefix" {
  description = "Crossplaneが作成するS3バケット名のプレフィックス (例: idp)"
  type        = string
  default     = "idp"
}
