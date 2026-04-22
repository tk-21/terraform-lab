# ─────────────────────────────────────────────
# Flink Event Output Bucket
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "output" {
  bucket        = "${var.name_prefix}-output-${var.aws_account_id}"
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "output" {
  bucket = aws_s3_bucket.output.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "output" {
  bucket = aws_s3_bucket.output.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "output" {
  bucket = aws_s3_bucket.output.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "output" {
  bucket = aws_s3_bucket.output.id

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }
  }
}

# ─────────────────────────────────────────────
# Flink Application Storage Bucket (JAR files)
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "flink_app" {
  bucket        = "${var.name_prefix}-flink-app-${var.aws_account_id}"
  force_destroy = true

  tags = var.tags
}

# Flinkアプリケーションのバージョン管理のためバージョニングを有効化
resource "aws_s3_bucket_versioning" "flink_app" {
  bucket = aws_s3_bucket.flink_app.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flink_app" {
  bucket = aws_s3_bucket.flink_app.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "flink_app" {
  bucket = aws_s3_bucket.flink_app.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
