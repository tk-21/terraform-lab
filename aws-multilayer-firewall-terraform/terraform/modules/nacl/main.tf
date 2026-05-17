# NACL はステートレスなサブネットレベルのファイアウォール。
# 戻りトラフィック（エフェメラルポート: 1024-65535）を
# 明示的に許可しなければ通信が成立しない点が SG との最大の違い。
# NACL は SG の補完として使用し、サブネット間の大雑把なトラフィック制御に用いる。
# ルール番号は 100 刻みにして後から挿入できる余地を持たせる。

locals {
  common_tags = merge(var.tags, {
    Project     = "aws-multilayer-firewall-terraform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  })
}

# -------------------------------------------------------------------
# amf-nacl-public: Public サブネット用
# -------------------------------------------------------------------
resource "aws_network_acl" "public" {
  vpc_id     = var.vpc_id
  subnet_ids = values(var.public_subnet_ids)

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nacl-public"
  })
}

# インバウンドルール
resource "aws_network_acl_rule" "public_inbound_http" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "public_inbound_https" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "public_inbound_ephemeral" {
  # 設計理由: ステートレスな NACL では、EC2 から開始した通信の
  # 戻りパケット（エフェメラルポート）を明示的に許可する必要がある。
  # SG はこれを自動で処理するが NACL は手動で記述しなければ通信が切れる。
  network_acl_id = aws_network_acl.public.id
  rule_number    = 120
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "public_inbound_deny_ssh" {
  # 設計理由: SSH（22番）をサブネットレベルで明示的に拒否する多層防御。
  # SG でも拒否しているが、NACL での拒否はサブネット全体に適用されるため、
  # SG の設定ミスがあっても SSH を受け付けない安全網になる。
  network_acl_id = aws_network_acl.public.id
  rule_number    = 200
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
  from_port      = 22
  to_port        = 22
}

resource "aws_network_acl_rule" "public_inbound_allow_all" {
  # 設計理由: 上記ルールで処理されなかったトラフィックを許可するデフォルト。
  # ルール番号 32766 は AWS の暗黙の DENY * より前に評価される。
  network_acl_id = aws_network_acl.public.id
  rule_number    = 32766
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# アウトバウンドルール
resource "aws_network_acl_rule" "public_outbound_all" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# -------------------------------------------------------------------
# amf-nacl-private: Private サブネット用
# -------------------------------------------------------------------
resource "aws_network_acl" "private" {
  vpc_id     = var.vpc_id
  subnet_ids = values(var.private_subnet_ids)

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nacl-private"
  })
}

# インバウンドルール
resource "aws_network_acl_rule" "private_inbound_app" {
  # 設計理由: Public サブネット（10.0.0.0/23）からの 8080 のみを許可し、
  # 直接インターネットからの到達を NACL レベルで防ぐ。
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "10.0.0.0/23"
  from_port      = 8080
  to_port        = 8080
}

resource "aws_network_acl_rule" "private_inbound_ephemeral" {
  # 設計理由: Private EC2 が外部へリクエストした際の戻りパケットを許可する。
  # 例: SSM Agent が VPC エンドポイントへ接続した際の応答など。
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_inbound_allow_all" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 32766
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# アウトバウンドルール
resource "aws_network_acl_rule" "private_outbound_all" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}
