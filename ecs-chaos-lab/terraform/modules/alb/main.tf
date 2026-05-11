locals {
  name_prefix = "${var.prefix}-${var.env}"
}

# Application Load Balancer (インターネット向け)
resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb"
  })
}

# ターゲットグループ
# target_type = "ip" は Fargate awsvpc モード必須設定。
# "instance" を指定すると Task が TG に登録されない。
resource "aws_lb_target_group" "main" {
  name        = "${local.name_prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    # FIS 実験中のヘルス変化を素早く検知するため短めに設定
    interval = 15
    timeout  = 5
    matcher  = "200"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-tg"
  })
}

# HTTP リスナー (80 → TG 転送)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-listener-http"
  })
}
