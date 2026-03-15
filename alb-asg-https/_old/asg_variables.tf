variable "asg_min_size" {
  type        = number
  description = "ASG min size"
  default     = 0
}

variable "asg_desired_capacity" {
  type        = number
  description = "ASG desired capacity"
  default     = 2
}

variable "asg_max_size" {
  type        = number
  description = "ASG max size"
  default     = 4
}
