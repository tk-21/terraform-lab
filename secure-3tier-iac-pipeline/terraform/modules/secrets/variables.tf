variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
