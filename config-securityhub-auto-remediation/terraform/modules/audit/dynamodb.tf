resource "aws_dynamodb_table" "remediation_log" {
  name         = "csar-remediation-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "remediation_id"
  range_key    = "timestamp"

  attribute {
    name = "remediation_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "resource_type"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  # リソース種別 × 時刻での検索用 (CloudWatch Dashboard等で使用)
  global_secondary_index {
    name            = "resource-type-index"
    hash_key        = "resource_type"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  # 修復ステータス × 時刻での検索用 (FAILED件数集計等)
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  # TTL: Lambdaが90日後のエポック秒を計算してセットする
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # AWSマネージドキーでの暗号化
  server_side_encryption {
    enabled = true
  }

  # ポイントインタイムリカバリ: 誤削除・誤更新への備え
  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = "csar-remediation-log"
  }
}
