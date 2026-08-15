locals {
  name_prefix = "${var.project}-${var.environment}"
}

# -----------------------------------------------------------------
# DynamoDB: テナント設定テーブル
# -----------------------------------------------------------------
resource "aws_dynamodb_table" "tenants" {
  name         = "${local.name_prefix}-tenants"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  # tier によるスキャンを効率化する GSI（Week4 以降のコスト集計で使用）
  global_secondary_index {
    name            = "tier-index"
    hash_key        = "tier"
    projection_type = "ALL"
  }

  attribute {
    name = "tier"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-tenants"
  }
}

# -----------------------------------------------------------------
# DynamoDB: トークン使用量テーブル
# router-lambda が日次集計で書き込み、cost-controller が読み取る
# -----------------------------------------------------------------
resource "aws_dynamodb_table" "usage" {
  name         = "${local.name_prefix}-usage"
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

  # 90日後に自動削除（コスト最適化）
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-usage"
  }
}

# -----------------------------------------------------------------
# デフォルトテナント（開発・テスト用）
# -----------------------------------------------------------------
resource "aws_dynamodb_table_item" "default_tenant" {
  table_name = aws_dynamodb_table.tenants.name
  hash_key   = "tenant_id"

  item = jsonencode({
    tenant_id           = { S = "default" }
    tier                = { S = "standard" }
    token_limit_daily   = { N = "100000" }
    token_limit_monthly = { N = "2000000" }
    guardrail_enabled   = { BOOL = true }
    created_at          = { S = "2026-01-01T00:00:00Z" }
  })
}

resource "aws_dynamodb_table_item" "premium_tenant" {
  table_name = aws_dynamodb_table.tenants.name
  hash_key   = "tenant_id"

  item = jsonencode({
    tenant_id = { S = "tenant-premium" }
    tier      = { S = "premium" }
    # dev の既定モデルは Marketplace サブスクリプション不要の Amazon Nova Lite。
    preferred_model     = { S = "amazon.nova-lite-v1:0" }
    token_limit_daily   = { N = "500000" }
    token_limit_monthly = { N = "10000000" }
    guardrail_enabled   = { BOOL = true }
    created_at          = { S = "2026-01-01T00:00:00Z" }
  })
}
