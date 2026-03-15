variable "name" { type = string }
variable "cidr" { type = string }

variable "public_subnets" {
  type = map(string) # az => cidr
}

variable "private_subnets" {
  type = map(string) # az => cidr
}
