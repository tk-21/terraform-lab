data "aws_caller_identity" "current" {}

# Terraformステートファイル保存用S3バケット
resource "aws_s3_bucket" "terraform_state" {
  bucket        = "tap-terraform-state-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
}

# ステートファイルのバージョン管理を有効化
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3でステートファイルを暗号化
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3バケットへのパブリックアクセスを全面遮断
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Terraformステートロック用DynamoDBテーブル
resource "aws_dynamodb_table" "terraform_lock" {
  name         = "tap-terraform-lock"
  hash_key     = "LockID"
  billing_mode = "PAY_PER_REQUEST"

  deletion_protection_enabled = true

  attribute {
    name = "LockID"
    type = "S"
  }
}
