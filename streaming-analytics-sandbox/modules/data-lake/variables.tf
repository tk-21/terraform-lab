variable "project" {
  description = "Project name used for naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "raw_retention_days" {
  description = "Days before transitioning raw data to STANDARD_IA"
  type        = number
  default     = 30
}
