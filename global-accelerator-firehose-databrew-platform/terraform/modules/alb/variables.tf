variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for ALB"
  type        = list(string)
}

variable "sg_alb_id" {
  description = "Security group ID for ALB"
  type        = string
}

variable "lambda_receiver_arn" {
  description = "ARN of the Lambda Receiver function"
  type        = string
}

variable "use_https" {
  description = "Whether to use HTTPS listener (requires acm_certificate_arn)"
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener"
  type        = string
  default     = ""
}
