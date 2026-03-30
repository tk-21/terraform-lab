# terraform/modules/storage/main.tf
#
# 監査ログ用 S3 バケットの設定。
# DynamoDB Streams から stream-processor Lambda 経由で監査ログを保存する。

resource "aws_s3_bucket" "audit_logs" {
  # 命名規則: sap-<env>-audit-logs-<account_id>
  # account_id をサフィックスに付けることでグローバル一意性を保証する
  bucket = "${var.prefix}-audit-logs-${var.account_id}"
}

resource "aws_s3_bucket_versioning" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit_logs" {
  bucket                  = aws_s3_bucket.audit_logs.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ライフサイクルポリシー
# 監査ログは頻繁にアクセスしないため、低コストのストレージクラスに移行する
resource "aws_s3_bucket_lifecycle_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  rule {
    id     = "audit-log-lifecycle"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA" # 30日後に低頻度アクセスクラスへ移行
    }

    transition {
      days          = 90
      storage_class = "GLACIER" # 90日後に Glacier へ移行（長期保存・低コスト）
    }

    expiration {
      days = 2555 # 7年後に削除（監査ログの一般的な保持期間）
    }
  }
}
