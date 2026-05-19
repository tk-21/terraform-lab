
variable "name_prefix" {
  description = "Peering接続名のプレフィックス（例: vnd-hub-to-prod）"
  type        = string
}

variable "requester_vpc_id" {
  description = "申請側VPC ID（Hub）"
  type        = string
}

variable "requester_vpc_cidr" {
  description = "申請側VPC CIDR（承認側のルートテーブルに追加するdestination）"
  type        = string
}

variable "requester_route_table_ids" {
  description = <<-EOT
    申請側のルートテーブルIDマップ。
    全tierのRTBを渡すこと（public/private両方）。
    例: { "private" = "rtb-xxx", "public" = "rtb-yyy" }
  EOT
  type        = map(string)
}

variable "accepter_vpc_id" {
  description = "承認側VPC ID（Spoke）"
  type        = string
}

variable "accepter_vpc_cidr" {
  description = "承認側VPC CIDR（申請側のルートテーブルに追加するdestination）"
  type        = string
}

variable "accepter_route_table_ids" {
  description = "承認側のルートテーブルIDマップ"
  type        = map(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
