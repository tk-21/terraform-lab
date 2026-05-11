variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "aws_account_id" {
  type = string
}

variable "project_name" {
  type    = string
  default = "eks-chaos-cell"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "owner" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
