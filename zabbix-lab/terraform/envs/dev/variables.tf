variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "name" {
  type    = string
  default = "zabbix-lab-dev"
}

# ★あなたのグローバルIP/CIDRを入れる（例: "203.0.113.10/32"）
# 迷う場合は一旦 0.0.0.0/0 でも動くが、セキュリティ的に推奨しない
variable "my_ip_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

variable "instance_type_server" {
  type    = string
  default = "t3.small"
}

variable "instance_type_target" {
  type    = string
  default = "t3.micro"
}

variable "ssh_key_name" {
  type    = string
  default = "zabbix-lab-key"
}
