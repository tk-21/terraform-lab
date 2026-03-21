data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Helper: per-bucket resource blocks
# ---------------------------------------------------------------------------

locals {
  buckets = {
    raw             = "${local.name_prefix}-raw-${local.account_id}"
    processed       = "${local.name_prefix}-processed-${local.account_id}"
    scripts         = "${local.name_prefix}-scripts-${local.account_id}"
    athena_results  = "${local.name_prefix}-athena-results-${local.account_id}"
  }
}

# ---------------------------------------------------------------------------
# raw zone  (Firehose → NDJSON)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "raw" {
  bucket        = local.buckets.raw
  force_destroy = true # dev only
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
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    id     = "raw-lifecycle"
    status = "Enabled"
    filter { prefix = "" }
    transition {
      days          = var.raw_retention_days
      storage_class = "STANDARD_IA"
    }
    expiration {
      # 3x retention (default: 90 days) — raw JSON is expendable once Parquet exists
      days = var.raw_retention_days * 3
    }
  }
}

# ---------------------------------------------------------------------------
# processed zone  (Glue ETL → Parquet)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "processed" {
  bucket        = local.buckets.processed
  force_destroy = true
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
  bucket                  = aws_s3_bucket.processed.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "processed" {
  bucket = aws_s3_bucket.processed.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id
  rule {
    id     = "processed-lifecycle"
    status = "Enabled"
    filter { prefix = "" }
    transition {
      days          = 60
      storage_class = "STANDARD_IA"
    }
    expiration { days = 180 }
  }
}

# ---------------------------------------------------------------------------
# scripts (Glue ETL script 置き場)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "scripts" {
  bucket        = local.buckets.scripts
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scripts" {
  bucket = aws_s3_bucket.scripts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  bucket                  = aws_s3_bucket.scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# athena-results  (Athena クエリ結果 — 7 日で自動削除)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "athena_results" {
  bucket        = local.buckets.athena_results
  force_destroy = true
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
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "athena-results-expire"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 7 }
  }
}
