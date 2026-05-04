provider "aws" {
  region = "ap-northeast-1"
}

locals {
  common_tags = {
    Project = var.prefix
  }
}

# VPCモジュール呼び出し
# モジュールはブラックボックスとして使う: 何を入力して何が出力されるかだけを意識する
module "vpc" {
  source = "../../modules/vpc"

  prefix = var.prefix
  env    = var.env

  vpc_cidr = "10.0.0.0/16"

  # map形式で渡すことで for_each が機能する
  # AZを増やしたいときはここにエントリを追加するだけでよい
  public_subnets = {
    "ap-northeast-1a" = "10.0.1.0/24"
    "ap-northeast-1c" = "10.0.2.0/24"
  }

  private_subnets = {
    "ap-northeast-1a" = "10.0.11.0/24"
    "ap-northeast-1c" = "10.0.12.0/24"
  }

  tags = local.common_tags
}

# EC2モジュール呼び出し
# vpc_id と subnet_id は module.vpc の output を直接参照する
# → terraform_remote_state 不要、モジュール間の依存が明確になる
module "ec2" {
  source = "../../modules/ec2"

  prefix    = var.prefix
  env       = var.env
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.public_subnet_ids[0]

  instance_type = "t3.micro"

  # ingress_rules を上書きしてSSHも許可する
  ingress_rules = [
    {
      description = "HTTP"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_ssh_cidrs
    }
  ]

  user_data = <<-EOT
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl start httpd
    systemctl enable httpd
    echo "<h1>Hello from ${var.prefix}-${var.env}</h1>" > /var/www/html/index.html
  EOT

  tags = local.common_tags
}
