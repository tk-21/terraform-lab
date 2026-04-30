# SageMaker Pipelinesのすべての中間成果物とモデルを保存するバケット
resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.prefix}-artifacts-${var.account_id}"

  tags = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "pipeline-artifacts-expiry"
    status = "Enabled"

    filter {
      prefix = "pipeline-artifacts/"
    }

    expiration {
      days = 90
    }
  }

  rule {
    id     = "model-artifacts-expiry"
    status = "Enabled"

    filter {
      prefix = "model-artifacts/"
    }

    expiration {
      days = 365
    }
  }
}

# 学習・推論・Model Monitor用データを格納。本番では別アカウントからのクロスアカウントアクセスを想定
resource "aws_s3_bucket" "data" {
  bucket = "${var.prefix}-data-${var.account_id}"

  tags = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
