variable "aws_region" {
  description = "AWSリージョン。CloudWatch Logsのロググループ ARN構築に使用する"
  type        = string
  default     = "ap-northeast-1"
}

variable "powertools_layer_version" {
  description = "Lambda Powertools V3 (Python3.12/arm64) のレイヤーバージョン番号"
  type        = number
  default     = 13
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
