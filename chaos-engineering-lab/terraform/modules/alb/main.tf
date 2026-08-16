locals {
  name_prefix = "${var.prefix}-${var.env}"
  bucket_name = "${var.prefix}-alb-logs-${var.account_id}"
}

# ── ALB アクセスログ用 S3 バケット ─────────────────────────────────────

resource "aws_s3_bucket" "alb_logs" {
  # ALB アクセスログを蓄積するバケット
  bucket        = local.bucket_name
  force_destroy = true

  tags = merge(var.tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "alb-logs-lifecycle"
    status = "Enabled"

    # 30 日後に Glacier へ移行（コスト削減）
    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    # 90 日後に完全削除
    expiration {
      days = 90
    }
  }
}

# ALB ログ配信用のバケットポリシー
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/${local.name_prefix}-alb/AWSLogs/${var.account_id}/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

# ── Application Load Balancer ───────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  # ALB アクセスログを S3 に出力する
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "${local.name_prefix}-alb"
    enabled = true
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-alb" })

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# ── ターゲットグループ ──────────────────────────────────────────────────

resource "aws_lb_target_group" "main" {
  name        = "${local.name_prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-tg" })
}

# ── リスナー ────────────────────────────────────────────────────────────

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-listener-http" })
}
