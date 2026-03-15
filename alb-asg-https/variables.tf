variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "ap-northeast-1"
}

variable "env" {
  type        = string
  description = "Environment name (e.g., dev, stg, prod)"
  default     = "dev"
}

variable "name_prefix" {
  type        = string
  description = "Prefix used for resource names"
  default     = "lab"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type        = map(string)
  description = "Public subnet CIDRs by AZ suffix. Example: { a = 10.0.1.0/24, c = 10.0.2.0/24 }"
  default = {
    a = "10.0.1.0/24"
    c = "10.0.2.0/24"
  }
}

variable "private_subnet_cidrs" {
  type        = map(string)
  description = "Private subnet CIDRs by AZ suffix (e.g. { a = 10.0.11.0/24, d = 10.0.12.0/24 })"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags"
  default     = {}
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 4
}

variable "req_per_target" {
  type    = number
  default = 100
}

variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access ALB (80/443)"
  default     = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to SSH to instances (empty disables SSH)"
  default     = []
}

variable "domain_name" {
  type        = string
  description = "FQDN (e.g. ecssafp.jp)"
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 Hosted Zone ID"
}

variable "enable_https_listener" {
  type        = bool
  description = "If true, ALB will redirect HTTP->HTTPS and create HTTPS listener"
  default     = false
}
