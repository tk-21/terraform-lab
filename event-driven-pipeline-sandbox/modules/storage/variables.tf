variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "job_retention_days" {
  description = "Number of days to retain job records (TTL)"
  type        = number
  default     = 30
}
