# =============================================================================
# S3モジュール - ポストモーテムHTMLレポート保存バケット
# report-formatter LambdaがHTMLレポートを保存し、presigned URLを発行する。
# パブリックアクセスを完全ブロックし、presigned URLでのみアクセスを許可する。
# =============================================================================

# ------------------------------------------------------------
# レポート保存バケット
# バケット名にアカウントIDを含めてグローバル一意性を保証する
# ------------------------------------------------------------
resource "aws_s3_bucket" "reports" {
  bucket = "${var.project}-reports-${var.aws_account_id}-${var.environment}"

  tags = var.tags
}

# ------------------------------------------------------------
# パブリックアクセスブロック
# 全オプションを有効にしてパブリックアクセスを完全禁止する（禁止パターン準拠）
# ------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------
# バージョニング
# レポートの誤上書き・誤削除からの復旧を可能にする
# ------------------------------------------------------------
resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ------------------------------------------------------------
# ライフサイクルルール
# 90日後にGlacierへ移行してストレージコストを削減する
# 365日後に完全削除（ポートフォリオ用途のためコスト優先）
# ------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "archive-to-glacier"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }

    # バージョニング有効時の古いバージョン管理
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ------------------------------------------------------------
# CORS設定
# presigned URLをブラウザから直接開く際のCORS制限を緩和する
# GETのみ許可してセキュリティリスクを最小化する
# ------------------------------------------------------------
resource "aws_s3_bucket_cors_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ------------------------------------------------------------
# サーバーサイド暗号化
# デフォルトでSSE-S3暗号化を有効化（レポートデータの保護）
# ------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
