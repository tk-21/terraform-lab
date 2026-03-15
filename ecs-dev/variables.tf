variable "aws_region" {
  default = "ap-northeast-1"
}

variable "project" {
  default = "handson"
}

variable "env" {
  default = "ecs-dev"
}

variable "image_tag" {
  type    = string
  default = "v1"
}
