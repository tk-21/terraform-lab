# 内部 ALB のアクセスログを保管するための S3 バケット。
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${local.name}-${data.aws_caller_identity.current.account_id}-${var.region}-alb-logs"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
