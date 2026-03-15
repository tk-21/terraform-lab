variable "name" {
  type    = string
  default = "lamp-fast"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

# 例: "203.0.113.10/32" のように自分のグローバルIPを入れる
variable "ssh_allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

# 先ほど作った公開鍵パス
variable "public_key_path" {
  type    = string
  default = "../lamp-fast-key.pub"
}
