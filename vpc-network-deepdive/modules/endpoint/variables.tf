variable "prefix" {
  description = "リソース名プレフィックス（例: vnd-prod）"
  type        = string
}

variable "vpc_id" {
  description = "EndpointとSGを配置するVPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "Endpoint SGのIngressに使用するVPC CIDR（VPC内通信のみ許可）"
  type        = string
}

variable "region" {
  description = "AWSリージョン（サービス名 com.amazonaws.{region}.{service} の組み立てに使用）"
  type        = string
  default     = "ap-northeast-1"
}

variable "subnet_ids" {
  description = "Interface EndpointのENIを配置するサブネットIDリスト（マルチAZ推奨）"
  type        = list(string)
}

variable "route_table_ids" {
  description = "Gateway EndpointのPrefix Listルートを追加するルートテーブルIDリスト"
  type        = list(string)
}

variable "gateway_endpoints" {
  description = <<-EOT
    Gateway型Endpointの定義マップ。
    例: { "s3" = { policy = null }, "dynamodb" = { policy = null } }
    Gateway型はENIを作成せずルートテーブルへのルート追加のみ行うため追加コストゼロ。
  EOT
  type = map(object({
    policy = optional(string, null)
  }))
  default = {}
}

variable "interface_endpoints" {
  description = <<-EOT
    Interface型Endpointのサービス名セット。
    例: ["ssm", "ssmmessages", "ec2messages"]
    各サービス名ごとにENIが作成され、$0.014/時/AZのコストが発生する。
  EOT
  type        = set(string)
  default     = []
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
