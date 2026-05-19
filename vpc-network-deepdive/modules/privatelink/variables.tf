variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "vpc_id" {
  description = "NLBとEC2を配置するVPC ID"
  type        = string
}

variable "service_subnet_id" {
  description = "NginxサービスEC2を配置するサブネットID（Hubプライベート）"
  type        = string
}

variable "nlb_subnet_ids" {
  description = "NLBのENIを配置するサブネットIDリスト（マルチAZ）"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "Nginx SGへの許可CIDRリスト（NLBとSpokeのCIDR）"
  type        = list(string)
}

variable "allowed_principals" {
  description = <<-EOT
    VPC Endpoint ServiceへのアクセスをConsumerアカウントに制限。
    例: ["arn:aws:iam::123456789012:root"]
    学習用途では同一アカウントのARNを指定。
  EOT
  type        = list(string)
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
