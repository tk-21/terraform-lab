# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"

  # パブリックサブネットに ALB を配置し、インターネットからのアクセスを受け付ける
  subnets         = var.public_subnet_ids
  security_groups = [var.sg_alb_id]

  # アクセスログは今回省略 (コスト削減) — 本番では S3 に出力すること
  enable_deletion_protection = false

  tags = { Name = "${var.name_prefix}-alb" }
}

# ターゲットグループ (Blue 環境)
resource "aws_lb_target_group" "blue" {
  name        = "${var.name_prefix}-tg-blue"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Fargate は ENI ベースなので ip タイプ必須

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = { Name = "${var.name_prefix}-tg-blue" }
}

# ターゲットグループ (Green 環境 — Blue/Green デプロイ用)
resource "aws_lb_target_group" "green" {
  name        = "${var.name_prefix}-tg-green"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = { Name = "${var.name_prefix}-tg-green" }
}

# HTTP リスナー — 本番トラフィックは Blue TG へ
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # CodeDeploy が Blue/Green 切り替え時にこのリスナーを操作するため
  # lifecycle で外部変更を無視する
  lifecycle {
    ignore_changes = [default_action]
  }
}

# テスト用リスナー (Green 環境の動作確認に使用)
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}
