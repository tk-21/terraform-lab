variable "project"               { type = string }
variable "environment"           { type = string }
variable "private_subnet_ids"    { type = list(string) }
variable "public_subnet_ids"     { type = list(string) }
variable "app_sg_id"             { type = string }
variable "bastion_sg_id"         { type = string }
variable "instance_type_app"     {
  type    = string
  default = "t4g.small"
}
variable "instance_type_bastion" {
  type    = string
  default = "t4g.micro"
}
