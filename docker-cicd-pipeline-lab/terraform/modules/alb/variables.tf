variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "sg_alb_id" { type = string }
