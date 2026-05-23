variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "region" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "route_table_ids" { type = list(string) }
