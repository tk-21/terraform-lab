variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

variable "alb_listener_arn" { type = string }
variable "alb_sg_id" { type = string }

variable "container_image" { type = string }
variable "container_port" { type = number }
variable "desired_count" {
  type    = number
  default = 1
}
