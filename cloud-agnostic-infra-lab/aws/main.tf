# cloud-agnostic-infra-lab / AWS ベースライン
# 他クラウドと比較するための基準となる最小構成

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# VPC
# GCPのVPCはグローバルリソースだがAWSはリージョン単位 — ここが最初の差異
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true # GCPはデフォルト有効、AWSは明示が必要

  tags = merge(local.common_tags, { Name = "${var.project}-vpc" })
}

# ---------------------------------------------------------------------------
# サブネット
# AWSはAZ単位でサブネットを作る — GCPはリージョン単位のサブネットで異なる
# NAT Gatewayコスト($32/月)を避けるためプライベートサブネットは最小化
# ---------------------------------------------------------------------------
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true # プライベートサブネット不使用のためここで対応

  tags = merge(local.common_tags, { Name = "${var.project}-public-a" })
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.region}c"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${var.project}-public-c" })
}

# ---------------------------------------------------------------------------
# インターネットゲートウェイ
# GCPにはこの概念がない（ルートテーブルで0.0.0.0/0をdefault-internetに向ける）
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.project}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "${var.project}-rt-public" })
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# セキュリティグループ
# AWSはSGがステートフル — GCPのFirewallルールはステートレス（Ingressのみ）
# この「ステートフル vs ステートレス」は面接で必ず聞かれる差異
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name   = "${var.project}-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project}-alb-sg" })
}

resource "aws_security_group" "ec2" {
  name   = "${var.project}-ec2-sg"
  vpc_id = aws_vpc.main.id

  # ALBからのトラフィックのみ許可（直接外部公開しない）
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project}-ec2-sg" })
}

# ---------------------------------------------------------------------------
# Launch Template + Auto Scaling Group
# GCPのManaged Instance Groupに相当するがAPIの設計思想が違う
# ---------------------------------------------------------------------------
data "aws_ami" "amazon_linux_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"
    # ECS 最適化 AMI も一致するため、通常の AL2023 AMI に限定する。
    # t4g.nano では ECS の Docker/Containerd 常駐プロセスがメモリを圧迫する。
    values = ["al2023-ami-2023.*-kernel-6.1-arm64"]
  }
}

resource "aws_launch_template" "nginx" {
  name_prefix   = "${var.project}-"
  image_id      = data.aws_ami.amazon_linux_arm.id
  instance_type = "t4g.nano" # Graviton2 arm64 — コスト最小

  # Spotインスタンスで最大70%削減
  instance_market_options {
    market_type = "spot"
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y nginx
    cat > /usr/share/nginx/html/index.html << 'HTML'
    <h1>cloud-agnostic-infra-lab: AWS</h1>
    <p>Region: ap-northeast-1 | IaC: Terraform | Compute: t4g.nano Spot</p>
    HTML
    systemctl enable --now nginx
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.project}-ec2" })
  }
}

resource "aws_autoscaling_group" "nginx" {
  name                = "${var.project}-asg"
  vpc_zone_identifier = [aws_subnet.public_a.id, aws_subnet.public_c.id]
  target_group_arns   = [aws_lb_target_group.nginx.arn]
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1

  launch_template {
    id      = aws_launch_template.nginx.id
    version = "$Latest"
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }
}

# ---------------------------------------------------------------------------
# ALB
# GCPはCloud Load Balancingでグローバルが標準 — AWSはRegional/Globalを選択する
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]

  tags = local.common_tags
}

resource "aws_lb_target_group" "nginx" {
  name     = "${var.project}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx.arn
  }
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "terraform"
    Cloud       = "aws"
  }
}
