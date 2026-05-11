variable "project_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "public_subnets" {
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    "az-a" = { cidr = "10.0.0.0/24", az = "ap-northeast-1a" }
    "az-c" = { cidr = "10.0.1.0/24", az = "ap-northeast-1c" }
  }
}

variable "private_subnets" {
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    "az-a" = { cidr = "10.0.10.0/24", az = "ap-northeast-1a" }
    "az-c" = { cidr = "10.0.11.0/24", az = "ap-northeast-1c" }
  }
}
