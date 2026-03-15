variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "name" {
  type    = string
  default = "ecs-handson-dev"
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

# 初回は latest でOK。Ansibleが更新します。
variable "image_tag" {
  type    = string
  default = "latest"
}

# ★注意：この値は state に残り得ます（学習用ならOK、実務は SecretsManager/SSM を別途で）
variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}
