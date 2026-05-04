# =============================================================
# Step 2: EC2 — 仮想サーバー
#
# 【学習ポイント】
#   - Security Group のインバウンド / アウトバウンドルール設計
#   - data ソースで最新 AMI を動的取得する方法
#   - UserData でインスタンス起動時の初期設定を自動化
#   - Elastic IP でパブリック IP を固定化する方法
# =============================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Environment = "handson"
    ManagedBy   = "terraform"
    Project     = var.prefix
  }
}

# -------------------------------------------------------------
# data: 最新の Amazon Linux 2023 AMI を動的取得
# 【ポイント】
#   AMI ID はリージョンごと・時間経過で変わるためハードコード禁止
#   data ソースで常に最新を取得することでメンテナンスが不要になる
# -------------------------------------------------------------
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"] # AWS 公式の AMI のみ

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# -------------------------------------------------------------
# Security Group
# 【ポイント】
#   - インバウンド: 必要なポートのみ許可（最小権限の原則）
#   - アウトバウンド: 全許可（パッケージ取得・外部 API 呼び出しに必要）
#   - SSH は本来 0.0.0.0/0 ではなく自分の IP に絞るべき
# -------------------------------------------------------------
resource "aws_security_group" "web" {
  name        = "${var.prefix}-web-sg"
  description = "Web server security group - HTTP and SSH access"
  vpc_id      = var.vpc_id

  # HTTP アクセスを全許可
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH アクセス（変数で制限可能 - 本番では自分の IP のみに絞ること）
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  # アウトバウンドは全許可（dnf update などのパッケージ取得に必要）
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # 全プロトコル
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-web-sg"
  })
}

# -------------------------------------------------------------
# EC2 インスタンス
# 【ポイント】
#   - ami は data ソースから参照（ハードコード禁止）
#   - user_data で起動時に Apache を自動インストール
#   - <<-EOF の heredoc 構文でシェルスクリプトを埋め込む
# -------------------------------------------------------------
resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = var.key_name != "" ? var.key_name : null

  # 起動時に実行されるシェルスクリプト
  user_data = <<-EOF
    #!/bin/bash
    set -e  # エラー時に即座に停止

    # パッケージ更新 & Apache インストール
    dnf update -y
    dnf install -y httpd

    # Apache を自動起動設定
    systemctl enable httpd
    systemctl start httpd

    # インスタンス情報を HTML に書き込む
    HOSTNAME=$(hostname -f)
    AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    cat > /var/www/html/index.html <<HTML
    <!DOCTYPE html>
    <html>
    <head><title>Terraform Handson</title></head>
    <body style="font-family:sans-serif; padding:40px;">
      <h1>🚀 Terraform Handson — EC2</h1>
      <table border="1" cellpadding="8">
        <tr><td><b>Hostname</b></td><td>${HOSTNAME}</td></tr>
        <tr><td><b>Instance ID</b></td><td>${INSTANCE_ID}</td></tr>
        <tr><td><b>AZ</b></td><td>${AZ}</td></tr>
        <tr><td><b>Started</b></td><td>${TIMESTAMP}</td></tr>
      </table>
    </body>
    </html>
    HTML
  EOF

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-web-ec2"
  })
}

# -------------------------------------------------------------
# Elastic IP
# 【ポイント】
#   EIP を使わないと terraform destroy → apply のたびに
#   パブリック IP が変わってしまう
#   depends_on で IGW が先に作られることを保証する
# -------------------------------------------------------------
resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-web-eip"
  })
}
