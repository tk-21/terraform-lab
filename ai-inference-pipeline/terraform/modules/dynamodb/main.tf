# 推論結果の永続化先
# GSIでステータス別に絞り込みできるようにする（運用時のデバッグ効率向上のため）
resource "aws_dynamodb_table" "results" {
  name         = "${var.name_prefix}-results"
  billing_mode = "PAY_PER_REQUEST" # ハンズオンでアクセスが読めないためオンデマンド
  hash_key     = "job_id"
  range_key    = "created_at"

  attribute {
    name = "job_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  # ステータス別検索を可能にするGSI
  # 「失敗したジョブだけ一覧表示」等の運用クエリを想定
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
