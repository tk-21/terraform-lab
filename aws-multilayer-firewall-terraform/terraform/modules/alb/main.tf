# ハンズオン用の ALB。WAF の動作確認が目的のため EC2 は不要。
# fixed-response でリクエストを受け付け、WAF のブロック動作を確認する。

resource "aws_lb" "main" {
  name               = "${var.prefix}-alb"
  internal           = false
  load_balancer_type = "application"

  # Public サブネット全 AZ に配置（ALB は 2AZ 以上必須）
  subnets         = values(var.public_subnet_ids)
  security_groups = [var.sg_id]

  # 設計理由: ALB アクセスログは S3 必須だが、ハンズオンではコスト最適化のため無効
  # WAF ログ（CloudWatch）で代替する
  enable_deletion_protection = false

  tags = {
    Name = "${var.prefix}-alb"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # 設計理由: WAF の動作確認が目的のため固定レスポンスを返す
  # 実際のアプリを配置する場合は forward アクションに変更する
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "amf-lab: OK"
      status_code  = "200"
    }
  }
}
