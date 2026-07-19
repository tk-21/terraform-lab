# Phase 2 — CloudFront + WAF WebACL 基本構成

## 前フェーズの確認

以下が完了していること：
- ALB が HTTPS で応答している
- `terraform output alb_dns_name` で DNS 名が取得できる
- ACM 証明書（us-east-1）が検証済み

---

## このフェーズの目的

CloudFront ディストリビューションを作成し、WAF WebACL（マネージドルール）を
アタッチする。AWS が管理するルールセットを使いこなすことで、
「ゼロから書かなくても守れる」設計を体験する。

## 完了条件

- [ ] CloudFront ディストリビューションが Deployed 状態
- [ ] WAF WebACL が CloudFront にアタッチされている
- [ ] マネージドルール 4 種が有効（Count モードで開始）
- [ ] CloudFront 経由で Nginx にアクセスできる
- [ ] WAF サンプリングログで Count されたリクエストが確認できる

---

## 作成するファイル一覧

```
terraform/modules/
├── cloudfront/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── waf/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

---

## 実装指示

### modules/waf/main.tf

**重要**: WAF の `provider = aws.use1` を必ず指定すること
（CloudFront スコープの WAF は us-east-1 に作成する必要がある）

**aws_wafv2_web_acl**

以下の設定で作成すること：
```
name  = "wcsl-{env}-webacl"
scope = "CLOUDFRONT"   # ← REGIONAL ではない
```

**default_action**: `allow`（明示的にブロックされたもの以外は通す）

**マネージドルールグループ**（全て `override_action = count` で開始）

| ルールグループ | 優先度 | 説明 |
|--------------|--------|------|
| `AWSManagedRulesCommonRuleSet` | 10 | OWASP Top 10 基本対策 |
| `AWSManagedRulesKnownBadInputsRuleSet` | 20 | 既知の悪意あるペイロード |
| `AWSManagedRulesSQLiRuleSet` | 30 | SQL インジェクション特化 |
| `AWSManagedRulesAmazonIpReputationList` | 40 | AWS 脅威インテリジェンス |

**override_action を count にする理由**（コメントで必ず記述）：
```hcl
# 初期デプロイ時は count モードで誤検知（False Positive）を確認してから
# block に切り替える運用が本番標準。count モードでもメトリクスは記録される。
```

**visibility_config**（WebACL 全体 + 各ルール）：
```hcl
visibility_config {
  cloudwatch_metrics_enabled = true
  metric_name                = "wcsl-{env}-webacl"
  sampled_requests_enabled   = true  # コンソールでサンプリング確認可能にする
}
```

**レートリミットルール**（独自ルール、優先度 1）：
```hcl
rule {
  name     = "RateLimitPerIP"
  priority = 1

  action {
    block {}  # レートリミットは最初から block で問題ない
  }

  statement {
    rate_based_statement {
      limit              = 2000   # 5 分間で 2000 リクエスト/IP
      aggregate_key_type = "IP"
    }
  }
}
```

### modules/cloudfront/main.tf

**aws_cloudfront_distribution**

```
enabled             = true
is_ipv6_enabled     = true
price_class         = "PriceClass_100"
web_acl_id          = WAF WebACL の ARN（module.waf.webacl_arn）
```

**origin 設定**：
```hcl
origin {
  domain_name = var.alb_dns_name
  origin_id   = "alb-origin"

  custom_origin_config {
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "https-only"  # オリジンへは必ず HTTPS
    origin_ssl_protocols   = ["TLSv1.2"]
  }

  # CloudFront からのアクセスであることを示すカスタムヘッダー
  # Phase 4 で ALB が このヘッダーを検証するようにする
  custom_header {
    name  = "X-CloudFront-Secret"
    value = var.cloudfront_secret  # SSM Parameter Store から取得
  }
}
```

**default_cache_behavior**：
```hcl
default_cache_behavior {
  target_origin_id       = "alb-origin"
  viewer_protocol_policy = "redirect-to-https"
  allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
  cached_methods         = ["GET", "HEAD"]

  # ALB への動的リクエストはキャッシュしない
  forwarded_values {
    query_string = true
    headers      = ["Host", "Authorization", "CloudFront-Viewer-Country"]
    cookies {
      forward = "all"
    }
  }

  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 0
}
```

**geo_restriction**（最初はなし、Phase 4 で Lambda@Edge に移行）：
```hcl
restrictions {
  geo_restriction {
    restriction_type = "none"
  }
}
```

**viewer_certificate**：
```hcl
viewer_certificate {
  acm_certificate_arn      = var.acm_certificate_arn_use1
  ssl_support_method       = "sni-only"
  minimum_protocol_version = "TLSv1.2_2021"
}
```

### modules/waf/variables.tf・outputs.tf

outputs に含めること：
- `webacl_arn`（CloudFront アタッチ用）
- `webacl_id`
- `webacl_name`

### terraform/main.tf への追加

Phase 1 の `module "origin"` の後に追加：

```hcl
module "waf" {
  source = "./modules/waf"

  providers = {
    aws = aws.use1  # CloudFront スコープは us-east-1
  }

  project = var.project
  env     = var.env
}

module "cloudfront" {
  source = "./modules/cloudfront"

  project                  = var.project
  env                      = var.env
  alb_dns_name             = module.origin.alb_dns_name
  webacl_arn               = module.waf.webacl_arn
  acm_certificate_arn_use1 = module.origin.acm_certificate_arn_use1
  cloudfront_secret        = data.aws_ssm_parameter.cloudfront_secret.value
}

data "aws_ssm_parameter" "cloudfront_secret" {
  name = "/${var.project}/${var.env}/cloudfront-secret"
}
```

---

## 動作確認手順

```bash
# 1. WAF + CloudFront を適用
terraform apply

# 2. CloudFront ドメインにアクセス
CF_DOMAIN=$(terraform output -raw cloudfront_domain_name)
curl -I https://${CF_DOMAIN}
# → HTTP/2 200、Server: CloudFront ヘッダーがあること

# 3. WAF サンプリングログを確認（コンソール）
# AWS コンソール → WAF → waf-wcsl-dev-webacl → サンプリングされたリクエスト
# Count されたリクエストが表示されること

# 4. SQLi ペイロードを送信して Count 確認
curl "https://${CF_DOMAIN}/?id=1' OR '1'='1"
# → 200 が返るが（まだ count モード）WAF コンソールに記録されること
```

---

## 口頭説明チェック（フェーズ 2 完了後）

1. **WAF の CLOUDFRONT スコープと REGIONAL スコープの違い**
   - なぜ CloudFront WAF は us-east-1 に置く必要があるのか
   - ALB に直接 WAF をアタッチする場合は何が変わるか

2. **マネージドルールを count モードで始める理由**
   - False Positive とは何か、本番でいきなり block するリスク
   - count → block への切り替え判断基準

3. **CloudFront のカスタムヘッダー（X-CloudFront-Secret）の役割**
   - ALB に直接アクセスされた場合に何が起きるか
   - このヘッダーだけでは不十分な点（Phase 4 で補完する内容）

4. **レートリミットを独自ルールにした理由**
   - マネージドルールのレートリミットとの違い
   - `aggregate_key_type` に IP 以外を使う場合

---

## 次フェーズへの引き継ぎ情報

Phase 3 で必要になる値：
- `webacl_arn`（Kinesis Firehose のログ配信先設定に使用）
- `cloudfront_domain_name`（攻撃シミュレーションスクリプトで使用）