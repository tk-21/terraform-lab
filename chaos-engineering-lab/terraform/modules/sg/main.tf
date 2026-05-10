locals {
  name_prefix = "${var.prefix}-${var.env}"

  common_tags = merge(var.tags, {
    Module = "sg"
  })
}

# ALB 用セキュリティグループ
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB へのインターネットからの HTTP アクセスを許可"
  vpc_id      = var.vpc_id

  # インターネットからの HTTP アクセスを許可
  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 全アウトバウンドを許可（EC2 へのトラフィック転送に必要）
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# EC2 用セキュリティグループ
# SSH 開放は不要。アクセスは SSM Session Manager 経由で行う。
resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2-sg"
  description = "ALB からの HTTP トラフィックのみ受け付ける EC2 用 SG"
  vpc_id      = var.vpc_id

  # ALB SG からの HTTP のみ許可（インターネット直接アクセス禁止）
  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # HTTPS（将来の TLS 終端対応用として予約）
  ingress {
    description     = "HTTPS from ALB only (reserved for future TLS)"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # 全アウトバウンドを許可
  # SSM エンドポイント・yum リポジトリ・stress-ng パッケージ取得に必要
  egress {
    description = "Allow all outbound (SSM/yum/stress-ng)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}
