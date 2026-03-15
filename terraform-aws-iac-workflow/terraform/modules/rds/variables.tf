variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

variable "db_username" { type = string }
variable "db_password" {
  type      = string
  sensitive = true
}

variable "allowed_sg_ids" {
  type    = list(string)
  default = []
}
