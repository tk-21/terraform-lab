locals {
  prefix = "${var.project}-${var.env}"

  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

data "aws_caller_identity" "current" {}

# =============================================================================
# S3 バケット: WAF ログ保存先
# =============================================================================

resource "aws_s3_bucket" "waf_logs" {
  # アカウント ID をサフィックスに付けてグローバル一意性を保証
  bucket        = "${local.prefix}-waf-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # ハンズオン用: 本番では false にすること

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "waf_logs" {
  bucket                  = aws_s3_bucket.waf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 90 日後 Glacier 移行、365 日後削除でストレージコストを最小化
resource "aws_s3_bucket_lifecycle_configuration" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id

  rule {
    id     = "waf-logs-lifecycle"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# =============================================================================
# S3 バケット: Athena クエリ結果保存先
# =============================================================================

resource "aws_s3_bucket" "athena_results" {
  bucket        = "${local.prefix}-athena-results-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# IAM ロール: Kinesis Firehose → S3 書き込み用
# =============================================================================

data "aws_iam_policy_document" "firehose_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${local.prefix}-firehose-waf-logs"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "firehose_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.waf_logs.arn,
      "${aws_s3_bucket.waf_logs.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "firehose_s3" {
  name   = "s3-write"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose_s3.json
}

# =============================================================================
# Kinesis Firehose 配信ストリーム
# =============================================================================
# WAF ログは Kinesis Firehose にのみ配信可能（CloudWatch Logs への直接配信不可）
# 命名規則: "aws-waf-logs-" プレフィックスが必須（AWS 仕様）

resource "aws_kinesis_firehose_delivery_stream" "waf_logs" {
  name        = "aws-waf-logs-${var.project}-${var.env}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.waf_logs.arn

    # Athena パーティションプルーニング用プレフィックス: year/month/day でスキャン範囲を限定
    prefix              = "waf-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "waf-logs-errors/!{firehose:error-output-type}/"

    buffering_size     = 5   # MB（最小値: 低トラフィックのためコスト最適化）
    buffering_interval = 300 # 秒

    # GZIP 圧縮でストレージコスト削減
    compression_format = "GZIP"
  }

  tags = local.common_tags
}

# =============================================================================
# WAF ログ設定: WebACL と Firehose を接続
# =============================================================================

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_kinesis_firehose_delivery_stream.waf_logs.arn]
  resource_arn            = var.webacl_arn

  # ALLOW されたリクエスト（ヘルスチェック等）を除外してログコストを削減
  # BLOCK・COUNT されたリクエストのみ保存する
  logging_filter {
    default_behavior = "KEEP"

    filter {
      behavior    = "DROP"
      requirement = "MEETS_ALL"
      condition {
        action_condition {
          action = "ALLOW"
        }
      }
    }
  }
}

# =============================================================================
# Athena ワークグループ
# =============================================================================
# 1 クエリあたりのスキャン量上限を 1 GB に設定してコスト暴走を防止

resource "aws_athena_workgroup" "main" {
  name          = "${local.prefix}-waf"
  force_destroy = true
  tags          = local.common_tags

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"
    }
    bytes_scanned_cutoff_per_query = 1073741824 # 1 GB
  }
}

# =============================================================================
# Athena データベース
# =============================================================================

resource "aws_athena_database" "waf" {
  name   = "${var.project}_${var.env}_waf"
  bucket = aws_s3_bucket.athena_results.bucket
}

# =============================================================================
# Athena テーブル作成クエリ (Named Query として保存)
# =============================================================================
# Athena コンソールまたは以下の CLI で実行する:
#   aws athena start-query-execution \
#     --query-execution-context Database=${aws_athena_database.waf.name} \
#     --result-configuration OutputLocation=s3://<results-bucket>/query-results/ \
#     --query-string "<named_query_content>"

resource "aws_athena_named_query" "create_table" {
  name      = "create-waf-logs-table"
  database  = aws_athena_database.waf.name
  workgroup = aws_athena_workgroup.main.name

  query = <<-SQL
    CREATE EXTERNAL TABLE IF NOT EXISTS waf_logs (
      timestamp                   BIGINT,
      formatVersion               INT,
      webaclId                    STRING,
      terminatingRuleId           STRING,
      terminatingRuleType         STRING,
      action                      STRING,
      httpSourceName              STRING,
      httpSourceId                STRING,
      ruleGroupList               ARRAY<STRUCT<
        ruleGroupId:STRING,
        terminatingRule:STRUCT<ruleId:STRING,action:STRING>,
        nonTerminatingMatchingRules:ARRAY<STRUCT<ruleId:STRING,action:STRING>>,
        excludedRules:ARRAY<STRUCT<exclusionType:STRING,ruleId:STRING>>
      >>,
      rateBasedRuleList           ARRAY<STRUCT<rateBasedRuleId:STRING,limitKey:STRING,maxRateAllowed:INT>>,
      nonTerminatingMatchingRules ARRAY<STRUCT<ruleId:STRING,action:STRING>>,
      httpRequest                 STRUCT<
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
