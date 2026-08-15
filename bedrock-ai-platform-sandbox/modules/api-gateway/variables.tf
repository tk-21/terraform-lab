variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "router_lambda_invoke_arn" {
  description = "Router Lambda invoke ARN for API Gateway integration"
  type        = string
}

variable "router_lambda_function_name" {
  description = "Router Lambda function name for Lambda permission"
  type        = string
}

variable "throttle_burst_limit" {
  description = "API Gateway throttle burst limit (concurrent requests)"
  type        = number
  default     = 100
}

variable "throttle_rate_limit" {
  description = "API Gateway throttle rate limit (requests/sec)"
  type        = number
  default     = 50
}

variable "waf_rate_limit" {
  description = "WAF rate-based rule: max requests per 5-minute window per IP"
  type        = number
  default     = 1000
}

variable "enable_waf" {
  description = "Whether to create a regional WAF Web ACL. HTTP APIs cannot be associated directly; protect them through CloudFront or an ALB."
  type        = bool
  default     = false
}
