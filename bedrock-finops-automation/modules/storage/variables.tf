variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name (dev / stg / prod)"
  type        = string
}
