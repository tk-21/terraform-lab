variable "name" {
  type        = string
  description = "Base name (e.g. lab-dev)"
}

variable "domain_name" {
  type        = string
  description = "FQDN to issue certificate for (e.g. ecssafp.jp)"
}

variable "zone_id" {
  type        = string
  description = "Route53 Hosted Zone ID for domain"
}

variable "alb_dns_name" {
  type        = string
  description = "ALB DNS name (from module.alb.alb_dns_name)"
}

variable "alb_zone_id" {
  type        = string
  description = "ALB zone id (from module.alb.alb_zone_id)"
}

variable "tags" {
  type    = map(string)
  default = {}
}
