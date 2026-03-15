variable "name" {
  type        = string
  description = "Base name (e.g. <name_prefix>-<env>)"
}

variable "aws_region" {
  type        = string
  description = "Region prefix used for AZ suffix concat (e.g. ap-northeast-1)"
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_cidrs" {
  type        = map(string)
  description = "Public subnet CIDRs keyed by AZ suffix (e.g. {a=..., d=...})"
}

variable "private_subnet_cidrs" {
  type        = map(string)
  description = "Private subnet CIDRs keyed by AZ suffix (e.g. {a=..., d=...})"
}

variable "enable_s3_endpoint" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
