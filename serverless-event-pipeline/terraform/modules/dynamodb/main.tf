# DynamoDB テーブルモジュール
# テーブル設計・GSI・Streams・TTL・PITR を管理する。
#
# 管理テーブル:
#   1. sep-<env>-events       — イベントの書き込み先。Streams で aggregator を起動する。
#   2. sep-<env>-aggregations — aggregator が集計結果をアトミック加算で書き込む先。
#
# events テーブル設計:
#   PK: entity_id (String)  例: USER#u123
#   SK: event_ts  (String)  例: EVENT#2024-01-15T12:00:00Z
#
# GSI-1 (status-index):
#   PK: status   (String)  PENDING / PROCESSED / FAILED
#   SK: event_ts (String)

# ── イベントテーブル（sep-<env>-events）────────────────────────────

resource "aws_dynamodb_table" "events" {
  name         = "${var.project}-${var.environment}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "entity_id"
  range_key    = "event_ts"

  attribute {
    name = "entity_id"
    type = "S"
  }

  attribute {
    name = "event_ts"
    type = "S"
  }

  # GSI-1 の PK として定義。status-index で PENDING イベントの一括取得・障害調査に使用する。
  attribute {
    name = "status"
    type = "S"
  }

  # GSI-1: ステータス別クエリ。
  # 使用例: status="PENDING" でフィルタして未処理イベントを取得する。
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "event_ts"
    projection_type = "ALL"
  }

  # TTL: 30 日後に自動削除してストレージコストを削減する。
  # Lambda で expires_at に「現在時刻 + 30日」の Unix タイムスタンプをセットする。
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # Streams: aggregator Lambda がトリガーされるために NEW_AND_OLD_IMAGES を有効化する。
  # NEW_AND_OLD_IMAGES を選択する理由:
  #   MODIFY イベントで「変更前後の差分」を計算するために旧イメージが必要。
  #   差分集計により、DynamoDB Streams の at-least-once 配信による二重集計の影響を最小化する。
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # PITR: データ損失に備えたポイントインタイムリカバリ（最大 35 日前に復元可能）。
  # コストが発生するため本番のみ有効化する（dev は false）。
  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-events"
  })
}

# ── 集計テーブル（sep-<env>-aggregations）──────────────────────────
#
# aggregator Lambda が DynamoDB Streams イベントを受けてアトミック加算で書き込む。
#
# テーブル設計:
#   PK: aggregate_key (String)  例: USER#u123#2024-01-15
#   SK: metric_type   (String)  例: TOTAL_AMOUNT / VIEW_COUNT
#
# Lambda が書き込む属性（スキーマレスのためテーブル定義には不要）:
#   value      (Number) — ADD 式でアトミック加算する集計値
#   count      (Number) — ADD 式でアトミック加算するイベント件数
#   updated_at (String) — SET 式で更新時刻を記録する

resource "aws_dynamodb_table" "aggregations" {
  name         = "${var.project}-${var.environment}-aggregations"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "aggregate_key"
  range_key    = "metric_type"

  attribute {
    name = "aggregate_key"
    type = "S"
  }

  attribute {
    name = "metric_type"
    type = "S"
  }

  # Streams は集計テーブルには不要（下流トリガーを持たないため）
  stream_enabled = false

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-aggregations"
  })
}
