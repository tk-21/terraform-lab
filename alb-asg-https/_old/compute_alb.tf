locals {
  public_subnet_keys_2 = slice(sort(keys(module.network.public_subnet_ids)), 0, 2)

  selected_public_subnets = {
    for k in local.public_subnet_keys_2 : k => module.network.public_subnet_ids[k]
  }
}

# Amazon Linux 2023 の最新 AMI を取得（リージョン対応）
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------
# Security Groups
# -----------------------

# ALB用SG（外部からHTTPを受ける）
resource "aws_security_group" "alb" {
  name        = "${local.base_name}-sg-alb"
  description = "ALB security group"
  vpc_id      = module.network.vpc_id

  ingress {
    description = "HTTP from allowed CIDRs"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.base_name}-sg-alb" }
}

# EC2用SG（ALBからのHTTPだけ許可 + SSHは任意）
resource "aws_security_group" "web" {
  name        = "${local.base_name}-sg-web"
  description = "Web instances security group"
  vpc_id      = module.network.vpc_id

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

  tags = { Name = "${local.base_name}-sg-web" }
}

# -----------------------
# ALB + Target Group + Listener
# -----------------------
resource "aws_lb" "this" {
  name               = replace("${local.base_name}-alb", "_", "-")
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb.id]
  subnets         = [for _, id in local.selected_public_subnets : id]

  tags = { Name = "${local.base_name}-alb" }
}

resource "aws_lb_target_group" "web" {
  name        = replace("${local.base_name}-tg", "_", "-")
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.network.vpc_id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${local.base_name}-tg" }
}

resource "aws_lb_listener" "http" {
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
