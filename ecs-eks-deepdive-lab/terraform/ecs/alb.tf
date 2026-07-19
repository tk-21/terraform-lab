resource "aws_lb" "main" {
  name               = "deepdive-alb"
  internal           = false # Public Subnet に配置、外部からテスト可能
  load_balancer_type = "application"
  subnets            = local.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  tags = { Name = "deepdive-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "deepdive-api-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"
  # awsvpc モードで各タスクが独自 ENI を持つため、IP を直接登録する
  # インスタンス指定（instance）は awsvpc では使用不可

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "deepdive-api-tg" }
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

output "alb_dns_name" {
  description = "ALBのDNS名（curl テスト用）"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  value = aws_lb.main.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.api.arn
}
