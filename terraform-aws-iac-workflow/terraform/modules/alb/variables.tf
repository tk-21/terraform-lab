variable "name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }

variable "enable_https_listener" {
  type    = bool
  default = false
}

variable "certificate_arn" {
  type    = string
  default = ""
  validation {
    condition     = trimspace(var.certificate_arn) == "" || can(regex("^arn:aws:acm:", var.certificate_arn))
    error_message = "certificate_arn は空文字（HTTPS無効時）か、ACM証明書のARN（arn:aws:acm:...）を指定してください。"
  }
}
