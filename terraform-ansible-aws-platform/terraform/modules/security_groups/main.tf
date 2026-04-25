# =============================================================================
# Security Groups モジュール
#
# 3種類のSecurity Groupを管理する:
#   - ALB SG    : インターネットからのHTTP/HTTPS受信
#   - App SG    : ALB SGからのトラフィックのみ受信（SG参照で最小権限）
#   - Bastion SG: インバウンドなし（SSM Session Manager専用接続）
#
# 重要: 22番ポートは一切開放しない。SSHはSSM経由で代替する。
# =============================================================================

# -----------------------------------------------------------------------------
# ALB Security Group
# インターネット公開のためHTTP(80)/HTTPS(443)をすべてのIPから受け付ける
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-alb-sg"
  description = "ALB: Allow HTTP/HTTPS from Internet"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-alb-sg"
    Role = "alb"
  }
}

# ALB: HTTP(80) インバウンド - インターネット全体から許可
resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from Internet"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# ALB: HTTPS(443) インバウンド - インターネット全体から許可
resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS from Internet"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# ALB: アウトバウンド全許可
resource "aws_security_group_rule" "alb_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# App Security Group
# ALB SGからのトラフィックのみ受け入れる。
# CIDRではなくSecurity Groupを直接参照することで、ALBのIPが変わっても
# 自動的に追従でき、不要なIP範囲の開放を避けられる（最小権限の原則）。
# -----------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project}-${var.environment}-app-sg"
  description = "App EC2: Allow HTTP/HTTPS from ALB SG only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-app-sg"
    Role = "app"
  }
}

# App: HTTP(80) インバウンド - ALB SGからのみ許可（CIDR不使用）
resource "aws_security_group_rule" "app_ingress_http_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.app.id
  description              = "Allow HTTP from ALB SG only (not CIDR)"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
}

# App: HTTPS(443) インバウンド - ALB SGからのみ許可（CIDR不使用）
resource "aws_security_group_rule" "app_ingress_https_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.app.id
  description              = "Allow HTTPS from ALB SG only (not CIDR)"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
}

# App: アウトバウンド全許可（yum update、SSMエージェント通信など）
resource "aws_security_group_rule" "app_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# Bastion Security Group
# インバウンドルールは一切設定しない。
# 理由: BastionへのアクセスはSSH（22番ポート）を使わず、
#       AWS Systems Manager Session Manager経由でエージェント接続するため、
#       インバウンドのポート開放が不要。
#       これにより外部からの直接攻撃面をゼロにできる。
# -----------------------------------------------------------------------------
resource "aws_security_group" "bastion" {
  name        = "${var.project}-${var.environment}-bastion-sg"
  description = "Bastion: No inbound rules (SSM Session Manager only)"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-${var.environment}-bastion-sg"
    Role = "bastion"
  }
}

# Bastion: アウトバウンド全許可（SSMエージェントがAWSエンドポイントへ接続するために必要）
resource "aws_security_group_rule" "bastion_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.bastion.id
  description       = "Allow all outbound traffic for SSM agent communication"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}
