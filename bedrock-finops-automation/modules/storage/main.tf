# ============================================================
# modules/storage
# S3（レポート保存）+ DynamoDB（履歴管理）
# ============================================================

data "aws_caller_identity" "current" {}

# ============================================================
# S3 Bucket - FinOpsレポート保存
# ============================================================

resource "aws_s3_bucket" "reports" {
  # アカウントIDをサフィックスに付与してグローバル一意性を確保
  bucket = "${var.project_name}-reports-${var.environment}-${data.aws_caller_identity.current.account_id}"

  # dev環境ではterraform destroyで自動削除できるようにする
  force_destroy = var.environment == "dev" ? true : false
}

# バージョニング有効化（レポートの上書き履歴保持）
resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

# サーバーサイド暗号化（SSE-S3: AES256）
resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# パブリックアクセスブロック（全アクセスを拒否）
resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ライフサイクル設定
# 90日後にGlacierへ移行（コスト最適化）、1年後に完全削除
resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "reports-lifecycle"
    status = "Enabled"

    # 非カレントバージョン（上書きされた古いバージョン）は30日で削除
    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # カレントバージョンは90日後にGlacierへ移行
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # 1年後に完全削除（長期保持不要なため）
    expiration {
      days = 365
    }
  }
}

# ============================================================
# DynamoDB - レポート履歴管理
# ============================================================

resource "aws_dynamodb_table" "report_history" {
  name         = "${var.project_name}-report-history-${var.environment}"
  billing_mode = "PAY_PER_REQUEST" # サーバーレス課金（月1回実行のためプロビジョンド不要）
  hash_key     = "report_id"       # パーティションキー: "finops-202501"形式
  range_key    = "report_date"     # ソートキー: "2025-01"形式

  attribute {
    name = "report_id"
    type = "S"
  }

  attribute {
    name = "report_date"
    type = "S"
  }

  # ポイントインタイムリカバリ（誤削除対策）
  point_in_time_recovery {
    enabled = true
  }

  # テーブル暗号化（AWS管理キー）
  server_side_encryption {
    enabled = true
  }

  # TTL属性（expire_atで自動削除: 1年後）
  ttl {
    attribute_name = "expire_at"
    enabled        = true
  }
}
