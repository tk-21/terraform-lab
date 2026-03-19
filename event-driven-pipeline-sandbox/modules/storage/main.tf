locals {
  name_prefix = "${var.project}-${var.environment}"
}

# -----------------------------------------------------------------
# DynamoDB: jobs テーブル
# PK: job_id (S)
# GSI-1: status-created_at-index  → ステータス別一覧
# GSI-2: tenant_id-created_at-index → テナント別一覧
# TTL: expires_at（自動削除）
# Streams: NEW_AND_OLD_IMAGES（stream-processor が消費）
# -----------------------------------------------------------------
resource "aws_dynamodb_table" "jobs" {
  name         = "${local.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  # GSI-1: ステータス別一覧（例: PENDING 一覧でスタック検出）
  global_secondary_index {
    name            = "status-created_at-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  # GSI-2: テナント別一覧（テナントのジョブ履歴参照）
  global_secondary_index {
    name            = "tenant_id-created_at-index"
    hash_key        = "tenant_id"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  # TTL（expires_at 属性に Unix タイムスタンプを設定して自動削除）
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # DynamoDB Streams（stream-processor Lambda がジョブ変更を検知）
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-jobs"
  }
}

# -----------------------------------------------------------------
# DynamoDB: metrics テーブル
# テナント別・日次のジョブ実行集計
# PK: tenant_id (S)
# SK: date (S)  例: "2024-01-15"
# -----------------------------------------------------------------
resource "aws_dynamodb_table" "metrics" {
  name         = "${local.name_prefix}-metrics"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"
  range_key    = "date"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "date"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Name = "${local.name_prefix}-metrics"
  }
}
