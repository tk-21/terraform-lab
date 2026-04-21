# ============================================================
# S3 Module - global-accelerator-firehose-databrew-platform
# ============================================================

# ------------------------------------------------------------
# Bucket 1: Raw (Firehose書き込み先 / NDJSON)
# ------------------------------------------------------------
resource "aws_s3_bucket" "raw" {
  bucket        = "${var.name_prefix}-raw-${var.aws_account_id}"
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}-raw-${var.aws_account_id}"
  }
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    id     = "raw-lifecycle"
    status = "Enabled"

    transition {
      days          = 60
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 180
    }
  }
}

# ------------------------------------------------------------
# Bucket 2: Processed (DataBrew出力先 / Parquet)
# ------------------------------------------------------------
resource "aws_s3_bucket" "processed" {
  bucket        = "${var.name_prefix}-processed-${var.aws_account_id}"
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}-processed-${var.aws_account_id}"
  }
}

resource "aws_s3_bucket_versioning" "processed" {
  bucket = aws_s3_bucket.processed.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket = aws_s3_bucket.processed.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id

  rule {
    id     = "processed-lifecycle"
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

# ------------------------------------------------------------
# Bucket 3: Athena Results
# ------------------------------------------------------------
resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.name_prefix}-athena-results-${var.aws_account_id}"
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}-athena-results-${var.aws_account_id}"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "athena-results-lifecycle"
    status = "Enabled"

    expiration {
      days = 7
    }
  }
}
