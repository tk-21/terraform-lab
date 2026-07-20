variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_cidrs" { type = list(string) }
variable "common_tags" { type = map(string) }
