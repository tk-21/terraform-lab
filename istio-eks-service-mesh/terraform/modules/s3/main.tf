data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "reports" {
  # アカウントIDをサフィックスに付けてグローバルに一意なバケット名を保証
  bucket = "${var.project_name}-reports-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}-reports-${var.env}"
  }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# セキュリティ要件：パブリックアクセスを全てブロック
# HTMLレポートへのアクセスは署名付きURL（Presigned URL）で提供する
resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# コスト最適化：古いレポートファイルを自動削除
resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-old-reports"
    status = "Enabled"

    expiration {
      days = var.lifecycle_days
    }

    # バージョニング有効時の古いバージョンも削除
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# HTMLレポートをブラウザで直接表示するためのCORS設定
resource "aws_s3_bucket_cors_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}
