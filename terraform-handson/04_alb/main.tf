# =============================================================
# Step 4: ALB + Auto Scaling Group
#
# 【学習ポイント】
#   - ALB / Target Group / Listener の3層構造を理解する
#   - Launch Template で EC2 の雛形を定義する
#   - ASG で自動スケーリングの仕組みを体験する
#   - SG を2段階（ALB用・EC2用）に分けてセキュリティを強化する
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

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name";  values = ["al2023-ami-*-x86_64"] }
  filter { name = "state"; values = ["available"] }
}

# -------------------------------------------------------------
# ALB 用 Security Group
# 【ポイント】
#   インターネット → ALB への HTTP のみ許可
#   ALB から EC2 への通信は別の SG で制御する
# -------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.prefix}-alb-sg"
  description = "ALB security group - allow HTTP from internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound to EC2"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.prefix}-alb-sg" })
}

# -------------------------------------------------------------
# EC2 (ASG) 用 Security Group
# 【ポイント】
#   EC2 への HTTP は ALB の SG からのみ許可（直接アクセス禁止）
#   これにより ALB を必ず経由させるセキュアな構成になる
# -------------------------------------------------------------
resource "aws_security_group" "asg_web" {
  name        = "${var.prefix}-asg-web-sg"
  description = "ASG EC2 security group - allow HTTP from ALB only"
  vpc_id      = var.vpc_id

  # ALB の SG からのみ HTTP 許可（CIDR ではなく SG ID 指定）
  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.prefix}-asg-web-sg" })
}

# -------------------------------------------------------------
# ALB (Application Load Balancer)
# 【ポイント】
#   - internal = false でインターネット向け
#   - 複数のパブリックサブネットに配置して冗長化
# -------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids # 複数 AZ に配置

  tags = merge(local.common_tags, { Name = "${var.prefix}-alb" })
}

# -------------------------------------------------------------
# Target Group
# 【ポイント】
#   - ALB が転送先 EC2 の死活監視（ヘルスチェック）をする設定
#   - unhealthy_threshold: N 回連続失敗で「異常」と判定
#   - healthy_threshold:   N 回連続成功で「正常」に復帰
# -------------------------------------------------------------
resource "aws_lb_target_group" "web" {
  name     = "${var.prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2  # 2回連続成功で正常
    unhealthy_threshold = 3  # 3回連続失敗で異常
    interval            = 30 # 30秒ごとにチェック
    timeout             = 5  # 5秒でタイムアウト
    matcher             = "200" # HTTP 200 を正常とみなす
  }

  tags = merge(local.common_tags, { Name = "${var.prefix}-tg" })
}

# -------------------------------------------------------------
# Listener
# 【ポイント】
#   ALB の 80 番ポートに来たリクエストを Target Group に転送
#   HTTPS 化する場合はここに 443 の Listener を追加する
# -------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# -------------------------------------------------------------
# Launch Template
# 【ポイント】
#   ASG が EC2 を起動する際の「雛形」
#   AMI / インスタンスタイプ / SG / UserData を定義する
#   version = "$Latest" で常に最新の設定を使う
# -------------------------------------------------------------
resource "aws_launch_template" "web" {
  name_prefix   = "${var.prefix}-lt-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.asg_web.id]
  }

  # base64encode() でエンコードして渡す
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y httpd
    systemctl enable httpd
    systemctl start httpd

    HOSTNAME=$(hostname -f)
    AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    cat > /var/www/html/index.html <<HTML
    <!DOCTYPE html>
    <html>
    <head><title>ALB Handson</title></head>
    <body style="font-family:sans-serif; padding:40px;">
      <h1>🔀 Terraform ALB + ASG Handson</h1>
      <p>リロードするたびに別の EC2 にルーティングされることを確認しよう！</p>
      <table border="1" cellpadding="8">
        <tr><td><b>Instance ID</b></td><td>${INSTANCE_ID}</td></tr>
        <tr><td><b>Hostname</b></td><td>${HOSTNAME}</td></tr>
        <tr><td><b>AZ</b></td><td>${AZ}</td></tr>
        <tr><td><b>Started</b></td><td>${TIMESTAMP}</td></tr>
      </table>
    </body>
    </html>
    HTML
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.prefix}-asg-instance"
    })
  }

  lifecycle {
    create_before_destroy = true # 新テンプレート作成後に古いものを削除
  }
}

# -------------------------------------------------------------
# Auto Scaling Group
# 【ポイント】
#   - min_size / max_size / desired_capacity でスケール幅を制御
#   - health_check_type = "ELB" で ALB のヘルスチェック結果を使う
#   - "EC2" だと OS 停止しないと異常と判定されないため ELB 推奨
# -------------------------------------------------------------
resource "aws_autoscaling_group" "web" {
  name                = "${var.prefix}-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = var.public_subnet_ids

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.web.arn]

  health_check_type         = "ELB" # ALB のヘルスチェック結果を使用
  health_check_grace_period = 60    # 起動直後の猶予時間（秒）

  tag {
    key                 = "Environment"
    value               = "handson"
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "terraform"
    propagate_at_launch = true
  }
}

# -------------------------------------------------------------
# スケーリングポリシー（CPU ベース）
# 【ポイント】
#   CPU 使用率 60% を超えると自動でスケールアウト
#   target_tracking_configuration が最もシンプルで推奨
# -------------------------------------------------------------
resource "aws_autoscaling_policy" "cpu_tracking" {
  name                   = "${var.prefix}-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0 # CPU 60% を維持するよう自動調整
  }
}
