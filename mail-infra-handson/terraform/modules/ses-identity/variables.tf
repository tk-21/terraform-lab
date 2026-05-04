variable "domain_name" {
  description = "SESで検証するドメイン名"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 Hosted Zone ID。DKIMのCNAMEレコードを登録するために使用する"
  type        = string
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
