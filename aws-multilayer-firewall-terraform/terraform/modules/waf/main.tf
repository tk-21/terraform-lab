# Network Firewall と WAF の役割分担:
#
# AWS Network Firewall（Phase 2）:
#   - VPC 全体のトラフィックを制御（East-West / North-South）
#   - L3/L4/L7 対応だが、HTTP の詳細解析は WAF が優れる
#   - ドメインフィルタリング・IPS ルールが強み
#   - 配置: Firewall Subnet（VPC 境界）
#
# AWS WAF（Phase 3）:
#   - ALB / CloudFront に直接アタッチ
#   - SQL インジェクション・XSS・Bot 対策に特化した豊富なルール
#   - リクエストヘッダー・Body・URI を詳細に検査できる
#   - レートベースルールで IP 単位のアクセス制限が容易
#   - 配置: ALB レベル（アプリ直前）
#
# 両者を組み合わせる理由:
#   Network Firewall が VPC 境界での粗いフィルタリング、
#   WAF がアプリ直前での精密なフィルタリングを担う多層防御。

# -------------------------------------------------------------------
# IP セット: 明示的なブロック対象リスト
# -------------------------------------------------------------------
resource "aws_wafv2_ip_set" "blocked" {
  name               = "${var.prefix}-waf-blocked-ips"
  scope              = "REGIONAL" # ALB 用は REGIONAL。CloudFront の場合は us-east-1 で CLOUDFRONT を使う
  ip_address_version = "IPV4"
  addresses          = var.blocked_ip_list

  # 設計理由: 本番では Threat Intel フィードから自動更新するが、
  # ハンズオンでは手動で管理し IP ブロックの即時効果を確認する
  tags = {
    Name = "${var.prefix}-waf-blocked-ips"
  }
}

# -------------------------------------------------------------------
# WAF WebACL
# -------------------------------------------------------------------
resource "aws_wafv2_web_acl" "main" {
  name  = "${var.prefix}-waf-alb"
  scope = "REGIONAL"

  # デフォルトアクション: 許可（ルールにマッチしないリクエストは通す）
  # 設計理由: ブラックリスト方式を採用。ホワイトリスト方式は既知の正規 IP のみ許可するが
  # ハンズオン環境では管理コストが高いため、既知の悪意あるパターンをブロックする方式にする
  default_action {
    allow {}
  }

  # --- ルール 1: ブロック IP セット（priority 10: 最優先）---
  rule {
    name     = "BlockedIPSet"
    priority = 10

    action {
      block {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.blocked.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BlockedIPSet"
      sampled_requests_enabled   = true
    }
  }

  # --- ルール 2: AWS マネージドルール（Core Rule Set）---
  # 設計理由: CRS は XSS・SQLi など OWASP Top 10 を幅広くカバーする
  # SizeRestrictions_BODY を COUNT にしているのは、大容量 POST を行う正規ユーザーを
  # ブロックしないよう移行期間中に観察するため（COUNT → BLOCK は metrics で判断）
  rule {
    name     = "AWSManagedRulesCRS"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCRS"
      sampled_requests_enabled   = true
    }
  }

  # --- ルール 3: AWS マネージドルール（既知の悪意ある入力）---
  rule {
    name     = "AWSManagedRulesKnownBadInputs"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  # --- ルール 4: レートベースルール ---
  # 設計理由: 5分間で 2000 リクエスト超は DDoS or スキャンとみなしてブロック
  # 閾値は業務要件に合わせて調整する。低すぎると正規ユーザーをブロックする
  rule {
    name     = "RateLimitRule"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  # --- ルール 5: カスタムルール（スキャナー UA ブロック）---
  # 設計理由: sqlmap は SQLi 自動スキャンツール。UA でフィルタするのは簡易的な手法だが
  # ツールのデフォルト UA を使う攻撃者を即座に排除できる
  rule {
    name     = "BlockScannerUA"
    priority = 50

    action {
      block {}
    }

    statement {
      byte_match_statement {
        field_to_match {
          single_header {
            name = "user-agent"
          }
        }
        positional_constraint = "CONTAINS"
        search_string         = "sqlmap"
        text_transformations {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BlockScannerUA"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.prefix}-waf-alb"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.prefix}-waf-alb"
  }
}

# -------------------------------------------------------------------
# WAF と ALB の紐付け
# -------------------------------------------------------------------
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
  # 設計理由: scope = REGIONAL の WebACL は ALB / API Gateway にアタッチ可能
  # CloudFront にアタッチする場合は scope = CLOUDFRONT かつ us-east-1 に作成する必要がある
}

# -------------------------------------------------------------------
# WAF ログ設定
# -------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "waf" {
  # WAF ログは必ず "aws-waf-logs-" プレフィックスが必要（AWS の制約）
  name              = "aws-waf-logs-${var.prefix}-alb"
  retention_in_days = 7

  # 設計理由: 7日保持はコスト最適化のため。セキュリティ調査に必要な直近ログを保持する
  tags = {
    Name = "aws-waf-logs-${var.prefix}-alb"
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn

  # 設計理由: BLOCK されたリクエストのみ記録してコスト最適化
  # 全リクエストを記録すると CloudWatch Logs のコストが急増する
  # COUNT や ALLOW のログが必要な場合は filter の condition を追加する
  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }
}
