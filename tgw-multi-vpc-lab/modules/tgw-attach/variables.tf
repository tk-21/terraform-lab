variable "tgw_id" {
  description = "アタッチ先のTransit Gateway ID"
  type        = string
}

variable "vpc_id" {
  description = "アタッチするVPCのID"
  type        = string
}

variable "tgw_subnet_ids" {
  description = "TGW専用サブネットのIDリスト（各AZに1つ）"
  type        = list(string)
}

variable "attachment_name" {
  description = "アタッチメントの識別名（例: hub, spoke-a）"
  type        = string
}

variable "route_table_id" {
  description = "このアタッチメントを関連付けるTGWルートテーブルID（Associationに使用）"
  type        = string
}

variable "propagate_to_route_table_ids" {
  description = "このVPCのCIDRを伝播するTGWルートテーブルIDのリスト"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "付与するタグのマップ"
  type        = map(string)
  default     = {}
}
