locals {
  base_name = var.name

  # public subnet のうち、2つだけ使う（AZ分散想定）
  public_subnet_keys_2 = slice(sort(keys(var.public_subnet_ids)), 0, 2)

  selected_public_subnets = [
    for k in local.public_subnet_keys_2 : var.public_subnet_ids[k]
  ]
}

# -----------------------
# Security Groups
# -----------------------

# ALB用SG（外部からHTTP/HTTPSを受ける）
resource "aws_security_group" "alb" {
  name        = "${local.base_name}-sg-alb"
  description = "ALB security group"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from allowed CIDRs"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }

  # HTTPS(443) は enable_https_listener=true のときだけ開ける
  dynamic "ingress" {
    for_each = var.enable_https_listener ? [1] : []
    content {
      description = "HTTPS from allowed CIDRs"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.alb_ingress_cidrs
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.base_name}-sg-alb" })
}

# Web用SG（ALBからのHTTPだけ許可 + SSHは任意）
# ※ASGモジュールに切り出すときも、このSGをoutputsで渡せば最小差分で移行できます
resource "aws_security_group" "web" {
  name        = "${local.base_name}-sg-web"
  description = "Web instances security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  dynamic "ingress" {
    for_each = length(var.ssh_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "SSH from admin CIDRs"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_ingress_cidrs
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.base_name}-sg-web" })
}

# -----------------------
# ALB + Target Group + Listener
# -----------------------
resource "aws_lb" "this" {
  name               = replace("${local.base_name}-alb", "_", "-")
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb.id]
  subnets         = local.selected_public_subnets

  tags = merge(var.tags, { Name = "${local.base_name}-alb" })
}

resource "aws_lb_target_group" "web" {
  name        = replace("${local.base_name}-tg", "_", "-")
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${local.base_name}-tg" })
}

# HTTPS無効時：HTTP(80) は 200 を返す（疎通用）
resource "aws_lb_listener" "http_fixed" {
  count             = var.enable_https_listener ? 0 : 1
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "ok (http only). enable_https_listener=true to redirect to https."
      status_code  = "200"
    }
  }
}

# HTTPS有効時：HTTP(80) は HTTPS(443) にリダイレクト
resource "aws_lb_listener" "http_redirect" {
  count             = var.enable_https_listener ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS(443) forward -> target group (optional)
resource "aws_lb_listener" "https" {
  count = var.enable_https_listener ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  lifecycle {
    precondition {
      condition     = trimspace(var.certificate_arn) != ""
      error_message = "HTTPS listener を作るには certificate_arn が必要です（ACM発行→検証→2回目applyで enable_https_listener=true）。"
    }
  }
}
