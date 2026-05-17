# ✅Phase 3: AWS WAF 構築

## このフェーズの目標

- AWS WAF を ALB に紐付け、**L7（アプリケーション層）の脅威をブロック**する
- Network Firewall（L3-L7、VPC レベル）と WAF（L7、ALB レベル）の
  **役割分担と補完関係** を Terraform コードで表現する
- レートベースルールで DDoS 的なアクセスを自動制限する
- WAF ログを CloudWatch に出力し、ブロック理由を可視化する

---

## Network Firewall vs WAF の設計判断（必ずコメントで記載）

```
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
```

---

## Phase 2 完了の前提

- Network Firewall が `amf-nfw` として起動済み
- Public サブネットが存在し、ALB を配置できる状態であること

---

## 生成対象ファイル

### terraform/modules/alb/ （新規）

WAF のアタッチ先として ALB が必要なため、先に作成する。

**main.tf**:
- `aws_lb`: `internal = false`（インターネット向け）
  - `load_balancer_type = "application"`
  - サブネット: Public サブネット x 2AZ
  - SG: `amf-sg-web`
- `aws_lb_listener`: HTTP 80
  - デフォルトアクション: `fixed-response`（テスト用。実際の EC2 はないため）
    ```hcl
    default_action {
      type = "fixed-response"
      fixed_response {
        content_type = "text/plain"
        message_body = "amf-lab: OK"
        status_code  = "200"
      }
    }
    ```
- コメント: `# ハンズオン用の ALB。WAF の動作確認が目的のため EC2 は不要。`

**outputs.tf**:
- `alb_arn`
- `alb_dns_name`

---

### terraform/modules/waf/

**main.tf** — 以下のリソースを作成:

#### 1. IP セット: `amf-waf-blocked-ips`

```hcl
# 明示的なブロック対象 IP リスト
# 本番では Threat Intel フィードから自動更新するが、
# ハンズオンでは手動で管理する
resource "aws_wafv2_ip_set" "blocked" {
  name               = "${var.prefix}-waf-blocked-ips"
  scope              = "REGIONAL"  # ALB 用は REGIONAL
  ip_address_version = "IPV4"
  addresses          = var.blocked_ip_list  # variables.tf で定義

  # コメント: scope = "CLOUDFRONT" にすると CloudFront にアタッチ可能
}
```

#### 2. WebACL: `amf-waf-alb`

```hcl
resource "aws_wafv2_web_acl" "main" {
  name  = "${var.prefix}-waf-alb"
  scope = "REGIONAL"

  # デフォルトアクション: 許可（ルールでマッチしなかったものは通す）
  # ホワイトリスト方式にする場合は block に変更する
  default_action {
    allow {}
  }

  # --- ルール1: ブロック IP リスト ---
  rule {
    name     = "BlockedIPSet"
    priority = 10
    action { block {} }
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

  # --- ルール2: AWS マネージドルール（Core Rule Set）---
  # コスト注意: 有効化したルールの数に応じて WCU を消費する
  # CRS は XSS・SQLi など一般的な攻撃を幅広くカバー
  rule {
    name     = "AWSManagedRulesCRS"
    priority = 20
    override_action { none {} }  # マネージドルールのアクションをそのまま使用
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
        # 特定ルールを COUNT に変更してテスト（本番移行前の確認用パターン）
        rule_action_override {
          action_to_use { count {} }
          name = "SizeRestrictions_BODY"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCRS"
      sampled_requests_enabled   = true
    }
  }

  # --- ルール3: AWS マネージドルール（既知の悪意のある IP）---
  rule {
    name     = "AWSManagedRulesKnownBadInputs"
    priority = 30
    override_action { none {} }
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

  # --- ルール4: レートベースルール ---
  # 同一 IP から 5分間で 2000 リクエスト超えたらブロック
  # コメント: 閾値は業務要件に合わせて調整する。低すぎると正規ユーザーをブロックする。
  rule {
    name     = "RateLimitRule"
    priority = 40
    action { block {} }
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

  # --- ルール5: カスタムルール（User-Agent ベースのボットブロック）---
  rule {
    name     = "BlockScannerUA"
    priority = 50
    action { block {} }
    statement {
      byte_match_statement {
        field_to_match { single_header { name = "user-agent" } }
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
}
```

#### 3. WAF と ALB の紐付け

```hcl
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
  # コメント: scope = REGIONAL の WebACL は ALB / API Gateway に紐付け可能
}
```

#### 4. WAF ログ設定

```hcl
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn

  # ログフィルタ: BLOCK されたリクエストのみ記録（コスト最適化）
  logging_filter {
    default_behavior = "DROP"
    filter {
      behavior = "KEEP"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
      requirement = "MEETS_ANY"
    }
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  # WAF ログは必ず "aws-waf-logs-" プレフィックスが必要
  name              = "aws-waf-logs-${var.prefix}-alb"
  retention_in_days = 7
}
```

---

### terraform/modules/waf/variables.tf

```hcl
variable "prefix" {}
variable "alb_arn" {}
variable "blocked_ip_list" {
  type    = list(string)
  default = []
  description = "ブロック対象の IP アドレスリスト（CIDR 形式）"
}
```

---

### terraform/modules/waf/outputs.tf

```hcl
output "web_acl_arn" {
  value = aws_wafv2_web_acl.main.arn
}
output "web_acl_id" {
  value = aws_wafv2_web_acl.main.id
}
output "waf_log_group" {
  value = aws_cloudwatch_log_group.waf.name
}
```

---

## environments/dev/main.tf への追記

```hcl
module "alb" {
  source            = "../../modules/alb"
  prefix            = var.prefix
  public_subnet_ids = module.vpc.public_subnet_ids
  sg_id             = module.security_group.sg_web_id
  vpc_id            = module.vpc.vpc_id
}

module "waf" {
  source          = "../../modules/waf"
  prefix          = var.prefix
  alb_arn         = module.alb.alb_arn
  blocked_ip_list = var.blocked_ip_list
}
```

---

## 実行手順

```bash
cd terraform/environments/dev
terraform plan
terraform apply

# ALB の DNS 名を確認
terraform output -module=alb alb_dns_name
```

---

## フェーズ完了の定義

- [ ] `terraform apply` がエラーなく完了する
- [ ] WAF WebACL が ALB に紐付けられている（コンソールで確認）
- [ ] ALB の DNS にアクセスして "amf-lab: OK" が返る
- [ ] `curl` でスキャナー UA を付けたリクエストがブロックされる
  ```bash
  # ブロックされるはず（403 Forbidden）
  curl -H "User-Agent: sqlmap/1.0" http://{ALB_DNS}/
  
  # 通るはず（200 OK）
  curl http://{ALB_DNS}/
  ```
- [ ] CloudWatch Logs `aws-waf-logs-amf-alb` にブロックログが出力される
- [ ] WAF マネージドルールの WCU 消費量を確認できる

---

## 学習確認（Phase 3 終了後に自問）

**Q1**: WAF の `scope = "REGIONAL"` と `"CLOUDFRONT"` の違いは何か？
- CloudFront に WAF をアタッチする場合、WebACL はどのリージョンに作る必要があるか？

**Q2**: マネージドルールを `override_action { count {} }` にするユースケースは何か？
- COUNT にして何を観察し、どうなったら BLOCK に切り替えるか？

**Q3**: WAF のレートベースルールと Network Firewall のルールでは
どちらが先にリクエストを評価するか？トラフィックフローを説明できるか？

**Q4**: WAF ログを "BLOCK されたリクエストのみ" に絞った理由は？
- 全ログを出力するとどんな問題が起きるか？