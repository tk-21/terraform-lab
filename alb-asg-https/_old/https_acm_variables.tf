variable "domain_name" {
  type        = string
  description = "ALBに割り当てるFQDN（例: app.example.com）"
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 Hosted Zone ID（例: Z123456...）"
}

variable "certificate_sans" {
  type        = list(string)
  description = "追加SAN（必要なら）"
  default     = []
}
