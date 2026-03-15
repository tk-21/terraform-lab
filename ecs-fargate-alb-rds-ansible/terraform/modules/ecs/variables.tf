variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

variable "alb_target_group_arn" { type = string }
variable "alb_listener_arn" { type = string }

variable "container_port" { type = number }
variable "health_check_path" { type = string }

variable "ecr_repo_url" { type = string }
variable "image_tag" { type = string }

variable "aws_region" { type = string }
