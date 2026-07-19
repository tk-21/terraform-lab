variable "name" {
  description = "Transit Gatewayの名前"
  type        = string
}

variable "description" {
  description = "Transit Gatewayの説明"
  type        = string
  default     = ""
}

variable "amazon_side_asn" {
  description = "BGP用のASN（デフォルトはAWS標準のプライベートASN）"
  type        = number
  default     = 64512
}

variable "tags" {
  description = "付与するタグのマップ"
  type        = map(string)
  default     = {}
}
