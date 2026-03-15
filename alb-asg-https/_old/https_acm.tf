locals {
  # 既に main.tf 等で local.base_name がある前提
  alb_fqdn = var.domain_name
}

# -----------------------
# ACM Certificate（DNS検証）
# -----------------------
resource "aws_acm_certificate" "this" {
  domain_name               = local.alb_fqdn
  subject_alternative_names = var.certificate_sans
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.base_name}-acm"
  }
}

# DNS検証用レコード作成（Route53）
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

# 証明書の検証完了を待つ（これがあると apply が安定）
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# -----------------------
# HTTPS(443) Listener
# -----------------------
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# -----------------------
# Route53 ALIAS（app.example.com → ALB）
# -----------------------
resource "aws_route53_record" "alb_alias" {
  zone_id = var.route53_zone_id
  name    = local.alb_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
