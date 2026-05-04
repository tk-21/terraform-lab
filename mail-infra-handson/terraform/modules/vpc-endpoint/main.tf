data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  tags = merge(var.tags, { Module = "vpc-endpoint" })
}

# ============================================================
# Security Group（VPC Endpoint用）
# ============================================================

resource "aws_security_group" "ses_endpoint" {
  # VPC EndpointにアタッチするSecurity Group
  # EC2（Postfix）からの587ポート（SMTP with STARTTLS）のみ許可
  name        = "mail-handson-ses-endpoint-sg"
  description = "SES VPC Endpoint: EC2からのSMTP(587)のみ許可"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SMTP with STARTTLS from VPC"
    from_port   = 587
    to_port     = 587
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "mail-handson-ses-endpoint-sg" })
}

# ============================================================
# VPC Endpoint（SES SMTP / Interface型）
# ============================================================

resource "aws_vpc_endpoint" "ses_smtp" {
  # SES SMTPのVPC Endpoint (Interface型 / PrivateLink)
  #
  # このエンドポイントを使うことで:
  # 1. EC2からSESへの通信がインターネットに出ない（セキュリティ強化）
  # 2. NATゲートウェイが不要になる（コスト削減: NAT GW は約$0.045/時間）
  # 3. エンドポイントポリシーで送信元EC2ロールを制限できる
  #
  # private_dns_enabled = true:
  # email-smtp.{region}.amazonaws.com が自動的にVPC内エンドポイントへ解決される
  # → Postfixの設定変更なしにPrivateLinkが有効になる
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.email-smtp"
  vpc_endpoint_type = "Interface"

  subnet_ids         = data.aws_subnets.default.ids
  security_group_ids = [aws_security_group.ses_endpoint.id]

  private_dns_enabled = true

  policy = var.ec2_iam_role_arn != "" ? jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEC2RoleOnly"
      Effect    = "Allow"
      Principal = { AWS = var.ec2_iam_role_arn }
      Action    = "ses:SendRawEmail"
      Resource  = "*"
    }]
  }) : null

  tags = merge(local.tags, { Name = "mail-handson-ses-smtp-endpoint" })
}
