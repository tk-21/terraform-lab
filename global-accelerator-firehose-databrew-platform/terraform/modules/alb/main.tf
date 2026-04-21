resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.sg_alb_id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_target_group" "receiver" {
  name        = "${var.name_prefix}-receiver-tg"
  target_type = "lambda"
}

resource "aws_lambda_permission" "allow_alb" {
  statement_id  = "AllowALBInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_receiver_arn
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.receiver.arn
}

resource "aws_lb_target_group_attachment" "receiver" {
  target_group_arn = aws_lb_target_group.receiver.arn
  target_id        = var.lambda_receiver_arn
  depends_on       = [aws_lambda_permission.allow_alb]
}

resource "aws_lb_listener" "https" {
  count             = var.use_https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.receiver.arn
  }
}

resource "aws_lb_listener" "http_forward" {
  count             = var.use_https ? 0 : 1
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.receiver.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count             = var.use_https ? 1 : 0
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
