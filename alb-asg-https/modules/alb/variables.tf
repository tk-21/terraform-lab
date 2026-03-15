variable "name" {
  type        = string
  description = "Base name (e.g. lab-dev)"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type        = map(string)
  description = "Public subnet IDs keyed by AZ suffix (e.g. {a=..., c=...})"
}

variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access ALB (80/443)"
  default     = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidrs" {
  type        = list(string)
  description = "Optional SSH CIDRs for web instances SG (leave empty to disable)"
  default     = []
}

variable "health_check_path" {
  type    = string
  default = "/"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_https_listener" {
  type        = bool
  description = "Whether to create HTTPS listener (443)"
  default     = false
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN for HTTPS listener"
  default     = ""

  validation {
    condition = (
      !var.enable_https_listener
      || trimspace(var.certificate_arn) != ""
    )
    error_message = "enable_https_listener=true の場合、certificate_arn は必須です。まず ACM を apply して証明書を発行・検証し、次の apply で enable_https_listener=true にしてください。"
  }
}
