# Phase 3 — WAF カスタムルール + ログ分析基盤

## 前フェーズの確認

以下が完了していること：
- CloudFront 経由でアクセスが通っている
- WAF WebACL にマネージドルール 4 種がアタッチされている
- `terraform output webacl_arn` で ARN が取得できる

---

## このフェーズの目的

WAF カスタムルールを追加し、全リクエストログを
Kinesis Firehose → S3 → Athena のパイプラインで分析可能にする。
「攻撃を検知して・記録して・クエリで確認できる」状態を作る。

## 完了条件

- [ ] WAF カスタムルール（ヘッダー検証・URI パスブロック）が動作している
- [ ] マネージドルールを count → block に切り替えている
- [ ] WAF ログが S3 に届いている（Kinesis Firehose 経由）
- [ ] Athena テーブルが作成され、SQL クエリが実行できる
- [ ] ブロックされたリクエストを Athena で抽出できる

---

## 作成するファイル一覧

```
terraform/modules/
└── waf-logs/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
athena/queries/
    ├── top_blocked_ips.sql
    ├── rule_match_summary.sql
    └── country_breakdown.sql
```

---

## 実装指示

### modules/waf/main.tf への追加（カスタムルール）

既存の `aws_wafv2_web_acl` に以下のルールを追加すること：

**カスタムルール 1: 管理画面パスへのアクセスブロック（優先度 2）**
```hcl
rule {
  name     = "BlockAdminPaths"
  priority = 2

  action {
    block {
      custom_response {
        response_code = 403
        # カスタムレスポンスで攻撃者に情報を与えない
      }
    }
  }

  statement {
    regex_pattern_set_reference_statement {
      arn = aws_wafv2_regex_pattern_set.admin_paths.arn
      field_to_match {
        uri_path {}
      }
      text_transformation {
        priority = 0
        type     = "LOWERCASE"
      }
    }
  }
}
```

`aws_wafv2_regex_pattern_set` で以下のパスを定義：
```
/admin.*
/wp-admin.*
/phpmyadmin.*
/.env
/config.*
```

**カスタムルール 2: 不正 User-Agent ブロック（優先度 3）**
```hcl
# スキャンツール（sqlmap, nikto, nmap 等）の UA を検知してブロック
rule {
  name     = "BlockMaliciousUserAgents"
  priority = 3
  action   { block {} }

  statement {
    regex_pattern_set_reference_statement {
      arn = aws_wafv2_regex_pattern_set.malicious_ua.arn
      field_to_match {
        single_header { name = "user-agent" }
      }
      text_transformation {
        priority = 0
        type     = "LOWERCASE"
      }
    }
  }
}
```

UA パターン例：`sqlmap`, `nikto`, `nessus`, `masscan`, `zgrab`

**マネージドルールの count → block 切り替え**

Phase 2 で count にしていたルールのうち、
`AWSManagedRulesAmazonIpReputationList` と `AWSManagedRulesSQLiRuleSet` を block に変更：
```hcl
# Phase 3 でサンプリングログを確認後、誤検知がないことを確認して block に変更
override_action {
  none {}  # count {} から none {} に変更することで managed rule のデフォルト action が有効になる
}
```

### modules/waf-logs/main.tf

**Kinesis Firehose 配信ストリーム**

```hcl
# WAF ログは Kinesis Firehose のみに配信可能（CloudWatch Logs への直接配信不可）
# 命名規則: aws-waf-logs- プレフィックスが必須
resource "aws_kinesis_firehose_delivery_stream" "waf_logs" {
  name        = "aws-waf-logs-${var.project}-${var.env}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.waf_logs.arn

    # パーティション設定（Athena クエリの効率化）
    prefix              = "waf-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "waf-logs-errors/!{firehose:error-output-type}/"

    buffering_size     = 5    # MB（最小値、コスト最適化）
    buffering_interval = 300  # 秒

    # 圧縮でストレージコスト削減
    compression_format = "GZIP"
  }
}
```

**WAF ログ設定（WAF WebACL への接続）**

```hcl
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_kinesis_firehose_delivery_stream.waf_logs.arn]
  resource_arn            = var.webacl_arn

  # ヘルスチェックは除外してログコスト削減
  logging_filter {
    default_behavior = "KEEP"

    filter {
      behavior = "DROP"
      condition {
        action_condition {
          action = "ALLOW"
        }
      }
      requirement = "MEETS_ALL"
    }
  }
}
```

**S3 バケット**

```hcl
resource "aws_s3_bucket" "waf_logs" {
  bucket        = "${var.project}-${var.env}-waf-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true  # ハンズオン用：本番では false
}

# バージョニング・暗号化・パブリックアクセスブロックを必ず設定
resource "aws_s3_bucket_versioning" "waf_logs" { ... }
resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" { ... }
resource "aws_s3_bucket_public_access_block" "waf_logs" { ... }

# ライフサイクル：90 日後に Glacier、365 日後に削除
resource "aws_s3_bucket_lifecycle_configuration" "waf_logs" { ... }
```

**Athena データベース・テーブル**

```hcl
resource "aws_athena_database" "waf" {
  name   = "${var.project}_${var.env}_waf"
  bucket = aws_s3_bucket.athena_results.bucket
}

resource "aws_athena_named_query" "create_table" {
  name      = "create-waf-logs-table"
  database  = aws_athena_database.waf.name
  workgroup = aws_athena_workgroup.main.name

  query = <<-SQL
    CREATE EXTERNAL TABLE IF NOT EXISTS waf_logs (
      timestamp          BIGINT,
      formatVersion      INT,
      webaclId           STRING,
      terminatingRuleId  STRING,
      terminatingRuleType STRING,
      action             STRING,
      httpSourceName     STRING,
      httpSourceId       STRING,
      ruleGroupList      ARRAY<STRUCT<
        ruleGroupId:STRING,
        terminatingRule:STRUCT<ruleId:STRING,action:STRING>,
        nonTerminatingMatchingRules:ARRAY<STRUCT<ruleId:STRING,action:STRING>>,
        excludedRules:ARRAY<STRUCT<exclusionType:STRING,ruleId:STRING>>
      >>,
      rateBasedRuleList  ARRAY<STRUCT<rateBasedRuleId:STRING,limitKey:STRING,maxRateAllowed:INT>>,
      nonTerminatingMatchingRules ARRAY<STRUCT<ruleId:STRING,action:STRING>>,
      httpRequest        STRUCT<
        clientIp:STRING,
        country:STRING,
        headers:ARRAY<STRUCT<name:STRING,value:STRING>>,
        uri:STRING,
        args:STRING,
        httpVersion:STRING,
        httpMethod:STRING,
        requestId:STRING
      >
    )
    ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
    LOCATION 's3://${aws_s3_bucket.waf_logs.bucket}/waf-logs/'
    TBLPROPERTIES ('has_encrypted_data'='true');
  SQL
}
```

**Athena ワークグループ**（クエリコスト制限）：
```hcl
resource "aws_athena_workgroup" "main" {
  name = "${var.project}-${var.env}-waf"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"
    }
    # 1 クエリあたりのスキャン量上限（コスト制御）
    bytes_scanned_cutoff_per_query = 1073741824  # 1 GB
  }
}
```

**IAM ロール**（Firehose 用）：
S3 への書き込み権限のみ。ワイルドカード禁止。

### athena/queries/top_blocked_ips.sql

```sql
-- ブロックされたリクエスト数 TOP 20 の送信元 IP
SELECT
  httpRequest.clientIp                       AS client_ip,
  httpRequest.country                        AS country,
  COUNT(*)                                   AS blocked_count,
  MAX(from_unixtime(timestamp / 1000))       AS last_seen
FROM waf_logs
WHERE action = 'BLOCK'
  AND year  = '2025'
  AND month = '01'
GROUP BY 1, 2
ORDER BY blocked_count DESC
LIMIT 20;
```

### athena/queries/rule_match_summary.sql

```sql
-- ルールごとのマッチ数集計
SELECT
  terminatingRuleId    AS rule_id,
  action,
  COUNT(*)             AS match_count
FROM waf_logs
WHERE year  = '2025'
  AND month = '01'
GROUP BY 1, 2
ORDER BY match_count DESC;
```

### athena/queries/country_breakdown.sql

```sql
-- 国別リクエスト数とブロック率
SELECT
  httpRequest.country                        AS country,
  COUNT(*)                                   AS total_requests,
  SUM(CASE WHEN action = 'BLOCK' THEN 1 ELSE 0 END) AS blocked_count,
  ROUND(
    100.0 * SUM(CASE WHEN action = 'BLOCK' THEN 1 ELSE 0 END) / COUNT(*), 2
  )                                          AS block_rate_pct
FROM waf_logs
WHERE year  = '2025'
  AND month = '01'
GROUP BY 1
ORDER BY total_requests DESC;
```

---

## 動作確認手順

```bash
# 1. 攻撃シミュレーション送信
CF_DOMAIN=$(terraform output -raw cloudfront_domain_name)

# SQLi テスト（ブロックされること）
curl -v "https://${CF_DOMAIN}/?id=1' UNION SELECT 1,2,3--"

# 管理パスへのアクセス（ブロックされること）
curl -v "https://${CF_DOMAIN}/admin"
curl -v "https://${CF_DOMAIN}/.env"

# 不正 UA（ブロックされること）
curl -v -A "sqlmap/1.0" "https://${CF_DOMAIN}/"

# 2. S3 にログが届くのを待つ（最大 5 分）
aws s3 ls s3://${PROJECT}-${ENV}-waf-logs-${ACCOUNT_ID}/waf-logs/ --recursive | head -20

# 3. Athena でテーブル作成クエリを実行（コンソールまたは CLI）
aws athena start-query-execution \
  --query-string file://athena/queries/create_table.sql \
  --work-group wcsl-dev-waf

# 4. ブロック IP を確認
aws athena start-query-execution \
  --query-string file://athena/queries/top_blocked_ips.sql \
  --work-group wcsl-dev-waf
```

---

## 口頭説明チェック（フェーズ 3 完了後）

1. **WAF ログを CloudWatch Logs ではなく Kinesis Firehose に送る理由**
   - WAF の仕様上の制約（直接 CW Logs 配信は不可）
   - Firehose → S3 の利点（Athena との親和性・コスト）

2. **Athena のパーティション設計（year/month/day）の意味**
   - パーティションなしでクエリするとどうなるか
   - `bytes_scanned_cutoff_per_query` を設定する理由

3. **count → block に切り替えるタイミングの判断基準**
   - False Positive を確認する具体的な方法
   - 切り替えを段階的に行う場合のアプローチ

---

## 次フェーズへの引き継ぎ情報

Phase 4 で必要になる値：
- `cloudfront_distribution_id`（Lambda@Edge のアタッチ先）
- `waf_logs_bucket_name`（アラートの補足情報として使用）