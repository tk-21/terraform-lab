variable "name" { type = string }

variable "vpc_id" { type = string }
variable "subnet_id" { type = string }

variable "my_ip_cidr" { type = string }

variable "key_name" { type = string }

variable "instance_type_server" {
  type = string
}

variable "instance_type_target" {
  type = string
}
