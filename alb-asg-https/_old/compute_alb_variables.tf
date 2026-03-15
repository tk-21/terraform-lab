variable "instance_type" {
  type        = string
  description = "EC2 instance type"
  default     = "t3.micro"
}

variable "ssh_ingress_cidrs" {
  type        = list(string)
  description = "SSH allowed CIDRs (empty = no SSH open)"
  default     = []
}

variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "ALB HTTP(80) allowed CIDRs"
  default     = ["0.0.0.0/0"]
}
