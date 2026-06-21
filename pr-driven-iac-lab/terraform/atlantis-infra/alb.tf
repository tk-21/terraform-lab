# ──────────────────────────────────────────
# セキュリティグループ
# ──────────────────────────────────────────

# ALB用: GitHubからのwebhook受信のためHTTP/HTTPSをインターネットに公開
resource "aws_security_group" "alb" {
  name        = "atlantis-alb-sg"
  description = "AtlantisのALBにGitHub webhookを受け付けるSG"
  vpc_id      = aws_vpc.atlantis.id

  ingress {
    description = "HTTP (ACM未設定時の動作確認用)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (ACM証明書設定後に有効化)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "atlantis-alb-sg" })
}

# ECS用: ALBからのトラフィックのみ許可 (直接インターネットアクセス禁止)
resource "aws_security_group" "ecs" {
  name        = "atlantis-ecs-sg"
  description = "AtlantisのECSタスクへのアクセスをALBのみに制限"
  vpc_id      = aws_vpc.atlantis.id

  ingress {
    description     = "ALBからのみAtlantisポートへのアクセスを許可"
    from_port       = var.atlantis_port
    to_port         = var.atlantis_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "AWS APIへのアウトバウンド (VPC Endpoint経由)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "atlantis-ecs-sg" })
}

# ──────────────────────────────────────────
# Application Load Balancer
# ──────────────────────────────────────────

# Internet-facingにする理由: GitHubはパブリックIPからwebhookを送信するため
resource "aws_lb" "atlantis" {
  name               = "atlantis-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  # アクセスログはコスト削減のため無効 (本番では有効化推奨)
  enable_deletion_protection = false

  tags = merge(local.common_tags, { Name = "atlantis-alb" })
}

# ──────────────────────────────────────────
# Target Group
# ──────────────────────────────────────────

resource "aws_lb_target_group" "atlantis" {
  name        = "atlantis-tg"
  port        = var.atlantis_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.atlantis.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = merge(local.common_tags, { Name = "atlantis-tg" })
}

# ──────────────────────────────────────────
# Listeners
# ──────────────────────────────────────────

# HTTP 80: カスタムドメイン・ACM証明書がない場合の動作確認用
# 注意: 本番環境ではHTTPSのみとし、このリスナーでHTTPS(443)へリダイレクトすること
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.atlantis.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.atlantis.arn
  }
}
