# AWS Network Firewall はステートフルな L3-L7 ファイアウォール。
# SG・NACL が EC2/サブネットレベルの制御であるのに対し、
# Network Firewall は VPC レベルの集中制御ポイントとして機能する。
#
# 配置場所: Firewall 専用サブネット（/28 で十分）
# トラフィックフロー（Ingress）:
#   Internet → IGW → [Firewall Endpoint] → Public Subnet → EC2
# トラフィックフロー（Egress）:
#   EC2 → [Firewall Endpoint] → IGW → Internet
#
# ルートテーブルを操作して Firewall Endpoint 経由を強制することが核心。
# Firewall Endpoint の ID は Terraform の output から動的に取得する。

locals {
  common_tags = merge(var.tags, {
    Project     = "aws-multilayer-firewall-terraform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  })

  # Firewall Endpoint ID は apply 後に確定するため、sync_states から AZ を指定して取得する。
  # tolist() は順序不定のため AZ 名で明示的にフィルタリングする。
  firewall_endpoint_id = one([
    for ss in aws_networkfirewall_firewall.main.firewall_status[0].sync_states :
    ss.attachment[0].endpoint_id
    if ss.availability_zone == "ap-northeast-1a"
  ])
}

# -------------------------------------------------------------------
# CloudWatch Log Groups
# -------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "nfw_alert" {
  # 設計理由: ブロック・検知イベントを記録し、攻撃パターンの分析に使用する。
  # 保持 30 日はコストとトレーサビリティのバランス。本番は 90 日以上を推奨。
  name              = "/aws/network-firewall/${var.prefix}-nfw/alert"
  retention_in_days = 30

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nfw-alert-logs"
  })
}

resource "aws_cloudwatch_log_group" "nfw_flow" {
  # 設計理由: 全接続フローを記録しデバッグに使用するが、量が多くコスト増になりやすい。
  # ハンズオン用に 7 日に抑える。
  name              = "/aws/network-firewall/${var.prefix}-nfw/flow"
  retention_in_days = 7

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nfw-flow-logs"
  })
}

# -------------------------------------------------------------------
# ステートレスルールグループ
# -------------------------------------------------------------------
resource "aws_networkfirewall_rule_group" "stateless" {
  # 設計理由: パケット単位の高速フィルタリング（L3/L4）を担当する。
  # 明らかな悪意のある送信元 IP をここでドロップし、
  # 残りをステートフルエンジンへ転送して詳細検査する。
  name     = "${var.prefix}-nfw-stateless-rg"
  type     = "STATELESS"
  capacity = 100

  rule_group {
    rules_source {
      stateless_rules_and_custom_actions {
        # ループバックアドレスからの通信は攻撃や設定ミスの兆候
        stateless_rule {
          priority = 10
          rule_definition {
            actions = ["aws:drop"]
            match_attributes {
              sources {
                address_definition = "127.0.0.0/8"
              }
              destinations {
                address_definition = "0.0.0.0/0"
              }
            }
          }
        }
        # その他は全てステートフルルールへ転送して L7 検査を受けさせる
        stateless_rule {
          priority = 100
          rule_definition {
            actions = ["aws:forward_to_sfe"]
            match_attributes {
              sources {
                address_definition = "0.0.0.0/0"
              }
              destinations {
                address_definition = "0.0.0.0/0"
              }
            }
          }
        }
      }
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nfw-stateless-rg"
  })
}

# -------------------------------------------------------------------
# ステートフルルールグループ: ドメイン許可リスト
# -------------------------------------------------------------------
resource "aws_networkfirewall_rule_group" "domain_allowlist" {
  # 設計理由: 許可リスト方式（Allow List）を採用する。
  # デフォルト拒否にして必要なドメインのみ通過させることで、
  # 意図しないデータ持ち出しや C2 通信を防ぐ。
  # 「何でも通す」より「必要なものだけ通す」ゼロトラスト原則の実践。
  name     = "${var.prefix}-nfw-domain-rg"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["HTTP_HOST", "TLS_SNI"]
        targets = [
          ".amazonaws.com",   # AWS サービスエンドポイント（SSM / S3 など）
          ".amazonlinux.com", # OS アップデート用パッケージリポジトリ
          "example.com",      # 疎通確認用（Phase 4 の動作検証で使用）
        ]
      }
    }
    # STRICT_ORDER: ルールグループ間の優先度を policy 側で制御するために必須
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nfw-domain-rg"
  })
}

# -------------------------------------------------------------------
# ステートフルルールグループ: Suricata IPS
# -------------------------------------------------------------------
resource "aws_networkfirewall_rule_group" "ips" {
  # 設計理由: Suricata 互換ルールにより L7 の攻撃パターンを検出・ブロックする。
  # WAF が HTTP(S) の ALB レイヤーで検査するのに対し、
  # Network Firewall IPS は TCP ペイロードレベルで検査する補完的な役割。
  name     = "${var.prefix}-nfw-ips-rg"
  type     = "STATEFUL"
  capacity = 200

  rule_group {
    rules_source {
      rules_string = <<-RULES
        # SQL インジェクション: SELECT + FROM の組み合わせで基本パターンを検出
        drop http any any -> any any (msg:"SQL Injection Attempt"; content:"SELECT"; nocase; content:"FROM"; nocase; sid:1000001; rev:1;)
        drop http any any -> any any (msg:"SQL Injection UNION"; content:"UNION"; nocase; content:"SELECT"; nocase; sid:1000002; rev:1;)
        # ディレクトリトラバーサル: ../ でサーバーのファイルシステムを走査しようとする試み
        drop http any any -> any any (msg:"Directory Traversal"; content:"../"; sid:1000003; rev:1;)
        # 自動スキャンツール: Nikto の User-Agent 文字列を検出
        drop http any any -> any any (msg:"Nikto Scanner Detected"; content:"Nikto"; http_header; sid:1000004; rev:1;)
      RULES
    }
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nfw-ips-rg"
  })
}

# -------------------------------------------------------------------
# Firewall Policy
# -------------------------------------------------------------------
resource "aws_networkfirewall_firewall_policy" "main" {
  # 設計理由: policy でルールグループの適用順と default action を定義する。
  # stateful_default_actions = "aws:drop_strict" により
  # どのルールにもマッチしないトラフィックを全てブロックする（許可リスト方式の核心）。
  name = "${var.prefix}-nfw-policy"

  firewall_policy {
    # ステートレスデフォルト: フラグメントも含めて全てステートフルエンジンへ転送
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateless_rule_group_reference {
      priority     = 10
      resource_arn = aws_networkfirewall_rule_group.stateless.arn
    }

    # STRICT_ORDER: priority 順にルールグループを評価し、最初にマッチしたルールで決定する
    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    # ドメイン許可リストを先に評価（priority 10）
    stateful_rule_group_reference {
      priority     = 10
      resource_arn = aws_networkfirewall_rule_group.domain_allowlist.arn
    }
    # IPS ルールを後に評価（priority 20）
    stateful_rule_group_reference {
      priority     = 20
      resource_arn = aws_networkfirewall_rule_group.ips.arn
    }

    # 許可リストに載っていない全トラフィックをドロップ
    stateful_default_actions = ["aws:drop_strict"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nfw-policy"
  })
}

# -------------------------------------------------------------------
# Network Firewall 本体
# -------------------------------------------------------------------
resource "aws_networkfirewall_firewall" "main" {
  # 設計理由: ハンズオンのため 1AZ（ap-northeast-1a）のみに配置してコストを抑える。
  # 本番では全 AZ に配置することで Firewall Endpoint の単一障害点をなくす。
  # delete_protection = false でハンズオン後に terraform destroy しやすくする。
  name                = "${var.prefix}-nfw"
  vpc_id              = var.vpc_id
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn

  subnet_mapping {
    subnet_id = var.firewall_subnet_id_1a
  }

  delete_protection = false

  tags = merge(local.common_tags, {
    Name = "${var.prefix}-nfw"
  })
}

# -------------------------------------------------------------------
# ログ設定
# -------------------------------------------------------------------
resource "aws_networkfirewall_logging_configuration" "main" {
  firewall_arn = aws_networkfirewall_firewall.main.arn

  logging_configuration {
    # アラートログ: DROP / REJECT されたパケットのイベントを記録
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.nfw_alert.name
      }
    }
    # フローログ: 全 TCP セッションの開始・終了を記録（デバッグ・フォレンジック用）
    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.nfw_flow.name
      }
    }
  }
}
