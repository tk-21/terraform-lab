data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project_name}-results-${data.aws_caller_identity.current.account_id}"
}

# -----------------------------------------------------------------------
# Analyzer 結果保存バケット
# -----------------------------------------------------------------------
resource "aws_s3_bucket" "results" {
  bucket = local.bucket_name

  tags = var.tags
}

# パブリックアクセスをすべてブロック
resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# バージョニング有効化
resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id

  versioning_configuration {
    status = "Enabled"
  }
}

# サーバーサイド暗号化（SSE-S3 / AES256）
resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ライフサイクルルール: Analyzer 結果は 90 日後に自動削除
resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "delete-old-analyzer-results"
    status = "Enabled"

    filter {
      prefix = "analyzer-results/"
    }

    expiration {
      days = 90
    }

    # バージョニング有効時: 非最新バージョンも 90 日後に削除
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # 不完全なマルチパートアップロードを 7 日後にクリーンアップ
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
