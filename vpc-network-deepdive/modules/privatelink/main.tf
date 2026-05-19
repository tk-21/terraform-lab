# =============================================================
# PrivateLinkのプロバイダー側（Hubに配置）
#
# 構成:
#   [Hub EC2 (Nginx)] → [NLB] → [VPC Endpoint Service]
#                                      ↓
#                           [Consumer側 Interface Endpoint]
#                                      ↓
#                         [Spoke EC2からのアクセス]
#
# NLBが必要な理由:
# PrivateLinkはNLBまたはGLB（Gateway Load Balancer）をバックエンドとして要求する
# NLBが固定のENI IPを持つことで、PrivateLinkがルーティング先を特定できる
# =============================================================

# =============================================================
# PrivateLinkのバックエンドサービス用EC2（Nginx）
# HubのプライベートサブネットにNginxを動かすEC2を配置
# =============================================================
resource "aws_security_group" "service" {
  name        = "${var.prefix}-service-sg"
  description = "PrivateLinkバックエンドNginx用SG"
  vpc_id      = var.vpc_id

  # NLBからのHTTPリクエストを許可
  # NLBはクライアントのIPをそのまま透過するため、SpokeのCIDRも許可
  ingress {
    description = "NLBからのHTTPトラフィック"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.prefix}-service-sg" })
}

data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_iam_role" "service" {
  name = "${var.prefix}-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "service" {
  name = "${var.prefix}-service-profile"
  role = aws_iam_role.service.name
}

resource "aws_instance" "service" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = "t4g.nano"
  subnet_id              = var.service_subnet_id
  iam_instance_profile   = aws_iam_instance_profile.service.name
  vpc_security_group_ids = [aws_security_group.service.id]

  # ユーザーデータでNginxを起動し、識別可能なレスポンスを返す
  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y nginx
    systemctl enable --now nginx
    echo "<h1>Hub Service via PrivateLink - $(hostname)</h1>" > /usr/share/nginx/html/index.html
  EOF
  )

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2必須
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  tags = merge(var.tags, { Name = "${var.prefix}-service-ec2" })
}

# =============================================================
# Network Load Balancer
# PrivateLinkのバックエンドとして必須
# - internal = true: HubプライベートサブネットにのみENIを配置
# - cross_zone_load_balancing: マルチAZ対応
# =============================================================
resource "aws_lb" "this" {
  name               = "${var.prefix}-nlb"
  internal           = true # インターネット向けにしない
  load_balancer_type = "network"
  subnets            = var.nlb_subnet_ids

  enable_cross_zone_load_balancing = true # AZ間の偏りを防ぐ

  tags = merge(var.tags, { Name = "${var.prefix}-nlb" })
}

# NLBターゲットグループ（EC2をIPターゲットとして登録）
resource "aws_lb_target_group" "this" {
  name        = "${var.prefix}-tg"
  port        = 80
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${var.prefix}-tg" })
}

resource "aws_lb_target_group_attachment" "this" {
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.service.id
  port             = 80
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# =============================================================
# VPC Endpoint Service（PrivateLinkサービスの公開）
# NLBをバックエンドに指定し、ConsumerがInterface Endpointを作成できるようにする
# acceptance_required = false: Consumer側の承認なしに接続を許可（学習用）
# =============================================================
resource "aws_vpc_endpoint_service" "this" {
  acceptance_required        = false # 本番ではtrueにして承認フローを設ける
  network_load_balancer_arns = [aws_lb.this.arn]

  # どのAWSアカウントからConsumer Endpointを作成できるかを制御
  # 同一アカウントの場合はアカウントIDを指定
  allowed_principals = var.allowed_principals

  tags = merge(var.tags, { Name = "${var.prefix}-endpoint-service" })
}
