# Security Group はステートフルなファイアウォール。
# 戻りトラフィックを自動的に許可するため、outbound に明示的な許可は最小限でよい。
# インスタンスの役割（Web/App/Bastion）ごとに SG を分け、
# リソース間参照（SG ID 参照）を使って最小権限を表現する。

locals {
  common_tags = merge(var.tags, {
    Project     = "aws-multilayer-firewall-terraform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  })
}

# -------------------------------------------------------------------
# amf-sg-web: ALB/外部向け Web 層
# -------------------------------------------------------------------
resource "aws_security_group" "web" {
  # 設計理由: WAF を前段に置いた ALB 向け。HTTP/HTTPS を全インターネットに開放するが、
  # App 層への通信は amf-sg-app の 8080 のみに絞り横展開を防ぐ。
  name        = "${var.prefix}-sg-web"
  description = "Web層 - HTTP/HTTPS インバウンド、App層へのアウトバウンド"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPインバウンド (WAF/ALB経由を想定)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPSインバウンド"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "App層への8080アウトバウンド"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-sg-web"
    Role = "web"
  })
}

# -------------------------------------------------------------------
# amf-sg-app: アプリケーション層
# -------------------------------------------------------------------
resource "aws_security_group" "app" {
  # 設計理由: Web 層からの 8080 のみを受け付けることで、
  # 直接インターネットからのアクセスを完全に遮断する。
  # 外部 API 呼び出しは 443 のみ許可し、不要なポートでの通信を防ぐ。
  name        = "${var.prefix}-sg-app"
  description = "App層 - Web層からの8080のみ受付、外部APIへの443のみ許可"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Web層からの8080のみ許可"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    description = "外部APIへのHTTPS (例: 外部決済、通知サービス)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-sg-app"
    Role = "app"
  })
}

# -------------------------------------------------------------------
# amf-sg-ssm: Session Manager 用（EC2 に付与）
# -------------------------------------------------------------------
resource "aws_security_group" "ssm" {
  # SSM は EC2 からのアウトバウンド 443 のみで動作する。インバウンド不要。
  # SSM Agent が ssm/ec2messages/ssmmessages の各 VPC エンドポイントへ
  # アウトバウンド TCP 443 で接続することでセッションが確立される。
  name        = "${var.prefix}-sg-ssm"
  description = "SSM Session Manager用 - アウトバウンド443のみ、インバウンドなし"
  vpc_id      = var.vpc_id

  egress {
    description = "SSM エンドポイントへのHTTPS (VPC Endpoint経由)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-sg-ssm"
    Role = "ssm"
  })
}
