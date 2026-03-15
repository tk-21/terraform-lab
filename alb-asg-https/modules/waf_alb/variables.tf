variable "name" {
  type        = string
  description = "Base name (e.g. lab-dev)"
}

variable "alb_arn" {
  type        = string
  description = "ALB ARN to associate WAF with"
}

variable "enable_managed_common" {
  type    = bool
  default = true
}

variable "enable_managed_knownbad" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
