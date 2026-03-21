locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Athena Workgroup
#
# 学習ポイント:
#   bytes_scanned_cutoff_per_query でクエリ単位のスキャン上限を強制できる。
#   Parquet + SNAPPY に変換後は 1 GB も使わないが、
#   誤って raw ゾーン（JSON）の全件スキャンを防ぐ安全装置として機能する。
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "this" {
  name        = "${local.name_prefix}-wg"
  description = "Workgroup for ${var.project} ${var.environment} — 1 GB scan limit per query"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${var.athena_results_bucket_id}/results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff
    requester_pays_enabled             = false
  }
}

# ---------------------------------------------------------------------------
# Named Queries (分析クエリ集)
#
# Athena の Named Query は Workgroup に紐付いた再利用可能な SQL テンプレート。
# コンソールで "Saved queries" から呼び出せる。
# ---------------------------------------------------------------------------

# Q1: event_type 別のイベント件数（直近）
resource "aws_athena_named_query" "count_by_event_type" {
  name        = "${local.name_prefix}-count-by-event-type"
  description = "Count events grouped by event_type"
  workgroup   = aws_athena_workgroup.this.name
  database    = var.glue_database_name

  query = <<-SQL
    SELECT
      event_type,
      COUNT(*)           AS cnt,
      COUNT(DISTINCT user_id) AS unique_users
    FROM events
    GROUP BY event_type
    ORDER BY cnt DESC;
  SQL
}

# Q2: テナント別のイベント件数
resource "aws_athena_named_query" "count_by_tenant" {
  name        = "${local.name_prefix}-count-by-tenant"
  description = "Count events grouped by tenant_id"
  workgroup   = aws_athena_workgroup.this.name
  database    = var.glue_database_name

  query = <<-SQL
    SELECT
      tenant_id,
      event_type,
      COUNT(*) AS cnt
    FROM events
    GROUP BY tenant_id, event_type
    ORDER BY tenant_id, cnt DESC;
  SQL
}

# Q3: 時間別イベント件数（直近 24 時間）
resource "aws_athena_named_query" "hourly_volume" {
  name        = "${local.name_prefix}-hourly-volume"
  description = "Event volume per hour for the last 24 hours"
  workgroup   = aws_athena_workgroup.this.name
  database    = var.glue_database_name

  query = <<-SQL
    SELECT
      year,
      month,
      day,
      hour,
      COUNT(*) AS events
    FROM events
    WHERE
      from_iso8601_timestamp(timestamp)
        >= current_timestamp - INTERVAL '24' HOUR
    GROUP BY year, month, day, hour
    ORDER BY year, month, day, hour;
  SQL
}

# Q4: ファネル分析（購買フロー）
resource "aws_athena_named_query" "purchase_funnel" {
  name        = "${local.name_prefix}-purchase-funnel"
  description = "Count users at each stage of the purchase funnel"
  workgroup   = aws_athena_workgroup.this.name
  database    = var.glue_database_name

  query = <<-SQL
    WITH funnel AS (
      SELECT
        user_id,
        MAX(CASE WHEN event_type = 'page_view'   THEN 1 ELSE 0 END) AS viewed,
        MAX(CASE WHEN event_type = 'add_to_cart' THEN 1 ELSE 0 END) AS carted,
        MAX(CASE WHEN event_type = 'purchase'    THEN 1 ELSE 0 END) AS purchased
      FROM events
      GROUP BY user_id
    )
    SELECT
      SUM(viewed)    AS step1_page_view,
      SUM(carted)    AS step2_add_to_cart,
      SUM(purchased) AS step3_purchase,
      ROUND(100.0 * SUM(carted)    / NULLIF(SUM(viewed),    0), 1) AS view_to_cart_pct,
      ROUND(100.0 * SUM(purchased) / NULLIF(SUM(carted),    0), 1) AS cart_to_purchase_pct
    FROM funnel;
  SQL
}

# Q5: processed ゾーン用の CREATE EXTERNAL TABLE DDL
#     Glue Job 実行後、Athena で直接クエリするための外部テーブル定義
resource "aws_athena_named_query" "create_processed_table" {
  name        = "${local.name_prefix}-create-processed-table"
  description = "DDL to create external table for processed Parquet zone"
  workgroup   = aws_athena_workgroup.this.name
  database    = var.glue_database_name

  query = <<-SQL
    CREATE EXTERNAL TABLE IF NOT EXISTS events_processed (
      event_id    STRING,
      user_id     STRING,
      tenant_id   STRING,
      `timestamp` STRING,
      ingested_at STRING,
      payload     STRUCT<
        product_id : STRING,
        amount     : DOUBLE,
        query      : STRING
      >
    )
    PARTITIONED BY (
      event_type STRING,
      year       INT,
      month      INT,
      day        INT,
      hour       INT
    )
    STORED AS PARQUET
    LOCATION 's3://${var.processed_bucket_id}/events/'
    TBLPROPERTIES ('parquet.compress'='SNAPPY');
  SQL
}
