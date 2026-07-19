locals {
  prefix = "${var.project}-${var.env}"

  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# カスタムルール用 Regex Pattern Sets
# =============================================================================

# 管理画面・設定ファイルへのアクセスをブロックするパスパターン
resource "aws_wafv2_regex_pattern_set" "admin_paths" {
  name  = "${local.prefix}-admin-paths"
  scope = "CLOUDFRONT"

  regular_expression {
    regex_string = "^/admin"
  }
  regular_expression {
    regex_string = "^/wp-admin"
  }
  regular_expression {
    regex_string = "^/phpmyadmin"
  }
  regular_expression {
    regex_string = "^\\.env$"
  }
  regular_expression {
    regex_string = "^/config"
  }

  tags = local.common_tags
}

# sqlmap・nikto 等のスキャンツールが使う User-Agent パターン
resource "aws_wafv2_regex_pattern_set" "malicious_ua" {
  name  = "${local.prefix}-malicious-ua"
  scope = "CLOUDFRONT"

  regular_expression {
    regex_string = "sqlmap"
  }
  regular_expression {
    regex_string = "nikto"
  }
  regular_expression {
    regex_string = "nessus"
  }
  regular_expression {
    regex_string = "masscan"
  }
  regular_expression {
    regex_string = "zgrab"
  }

  tags = local.common_tags
}

# =============================================================================
# WAF WebACL (CLOUDFRONT スコープ)
# =============================================================================
# CLOUDFRONT スコープの WebACL は us-east-1 に作成する必要がある。
# このモジュールは providers = { aws = aws.use1 } で呼び出すこと。

resource "aws_wafv2_web_acl" "main" {
  name  = "${local.prefix}-webacl"
  scope = "CLOUDFRONT"

  # デフォルトは allow: 明示的にブロックしたもの以外は通す
  default_action {
    allow {}
  }

  # ===========================================================================
  # レートリミット (優先度 1: 最初に評価)
  # ===========================================================================
  # マネージドルールと異なり、独自ルールなので最初から block で問題ない。
  # IP ベース 2000 req/5min: ブルートフォースや DDoS の初動を抑止する。

  rule {
    name     = "RateLimitPerIP"
    priority = 1

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
      metric_name                = "${local.prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # ===========================================================================
  # カスタムルール: 管理画面パスブロック (優先度 2)
  # ===========================================================================
  # /admin, /wp-admin, /.env 等を 403 で返す。
  # カスタムレスポンスで攻撃者にサーバ情報を与えない。

  rule {
    name     = "BlockAdminPaths"
    priority = 2

    action {
      block {
        custom_response {
          response_code = 403
        }
      }
    }

    statement {
      regex_pattern_set_reference_statement {
        arn = aws_wafv2_regex_pattern_set.admin_paths.arn
        field_to_match {
          uri_path {}
        }
        text_transformations {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-block-admin-paths"
      sampled_requests_enabled   = true
    }
  }

  # ===========================================================================
  # カスタムルール: 不正 User-Agent ブロック (優先度 3)
  # ===========================================================================
  # sqlmap / nikto / nessus / masscan / zgrab 等の攻撃ツールを UA で検知してブロック。

  rule {
    name     = "BlockMaliciousUserAgents"
    priority = 3

    action {
      block {}
    }

    statement {
      regex_pattern_set_reference_statement {
        arn = aws_wafv2_regex_pattern_set.malicious_ua.arn
        field_to_match {
          single_header {
            name = "user-agent"
          }
        }
        text_transformations {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-block-malicious-ua"
      sampled_requests_enabled   = true
    }
  }

  # ===========================================================================
  # AWSManagedRulesCommonRuleSet (優先度 10)
  # ===========================================================================
  # OWASP Top 10 の基本的な攻撃パターンをカバーする AWS マネージドルール。
  # 初期デプロイ時は count モードで誤検知（False Positive）を確認してから
  # block に切り替える運用が本番標準。count モードでもメトリクスは記録される。

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # ===========================================================================
  # AWSManagedRulesKnownBadInputsRuleSet (優先度 20)
  # ===========================================================================
  # Log4Shell、Spring4Shell など既知の悪意あるペイロードをブロックするルール。
  # 初期デプロイ時は count モードで誤検知（False Positive）を確認してから
  # block に切り替える運用が本番標準。count モードでもメトリクスは記録される。

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ===========================================================================
  # AWSManagedRulesSQLiRuleSet (優先度 30)
  # ===========================================================================
  # SQL インジェクション攻撃に特化したマネージドルール。
  # Phase 3 でサンプリングログを確認し誤検知がないことを確認したため block に変更。
  # none {} = マネージドルール自身のデフォルトアクション（block）を有効化。

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-sqli-rules"
      sampled_requests_enabled   = true
    }
  }

  # ===========================================================================
  # AWSManagedRulesAmazonIpReputationList (優先度 40)
  # ===========================================================================
  # AWS 脅威インテリジェンスに基づく悪意ある IP アドレスリスト。
  # Phase 3 でサンプリングログを確認し誤検知がないことを確認したため block に変更。
  # none {} = マネージドルール自身のデフォルトアクション（block）を有効化。

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 40

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.prefix}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # WebACL 全体の visibility: コンソールでサンプリング確認が可能になる
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.prefix}-webacl"
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}
