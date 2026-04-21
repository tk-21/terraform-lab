variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB endpoint"
  type        = string
}

variable "raw_bucket_name" {
  description = "Name of the raw S3 bucket for flow logs"
  type        = string
}
