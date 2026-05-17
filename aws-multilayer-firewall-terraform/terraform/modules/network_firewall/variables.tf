variable "prefix" {
  description = "リソース名プレフィックス (例: amf)"
  type        = string
}

variable "environment" {
  description = "環境名 (例: dev)"
  type        = string
}

variable "vpc_id" {
  description = "Firewall を配置する VPC の ID"
  type        = string
}

variable "firewall_subnet_id_1a" {
  description = "Firewall Endpoint を配置する 1a のサブネット ID（コスト最適化で 1AZ のみ）"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public サブネット ID マップ (key: AZ suffix, e.g. '1a')"
  type        = map(string)
}

variable "public_subnet_cidrs" {
  description = "Public サブネット CIDR マップ (key: AZ suffix) — IGW Edge RT のルート生成に使用"
  type        = map(string)
}

variable "internet_gateway_id" {
  description = "VPC の Internet Gateway ID"
  type        = string
}

variable "public_route_table_id" {
  description = "Public サブネットに関連付けられた既存ルートテーブル ID（Egress ルートを上書きする）"
  type        = string
}

variable "tags" {
  description = "追加タグ（common_tags にマージされる）"
  type        = map(string)
  default     = {}
}
