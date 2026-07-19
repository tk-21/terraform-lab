locals {
  audit_bucket_name = "csar-audit-logs-${var.aws_account_id}"
  access_log_bucket = "csar-access-logs-${var.aws_account_id}"
}

# ─────────────────────────────────────────────
# アクセスログ格納用バケット (audit_bucketのログ受け口)
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "access_logs" {
  bucket = local.access_log_bucket

  # terraform destroy時に誤削除を防ぐためforceDestroyはfalse
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    # ACLを無効化してバケット所有者強制モードに設定
    object_ownership = "BucketOwnerEnforced"
  }
}

# ─────────────────────────────────────────────
# 監査ログバケット (修復ログのS3保存先)
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "audit" {
  bucket        = local.audit_bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# アクセスログを別バケットへ転送
resource "aws_s3_bucket_logging" "audit" {
  bucket        = aws_s3_bucket.audit.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3-access-logs/csar-audit-logs/"

  depends_on = [aws_s3_bucket.access_logs]
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "glacier-transition"
    status = "Enabled"

    filter {
      prefix = "remediation-logs/"
    }

    # 90日経過後にGlacierへ移行してストレージコストを削減
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # 365日経過後に削除 (コンプライアンス要件に応じて延長可能)
    expiration {
      days = 365
    }
  }
}

# ─────────────────────────────────────────────
# バケットポリシー: HTTPS強制
# ─────────────────────────────────────────────

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonHTTPS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.audit.arn,
          "${aws_s3_bucket.audit.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
