data "aws_caller_identity" "current" {}

locals {
  # アカウントIDを含めてバケット名のグローバル一意性を保証する
  bucket_name = "handson-tfstate-${data.aws_caller_identity.current.account_id}"
}

# tfstate保存用S3バケット
resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  # 誤削除防止: terraform destroy でも消えないようにする
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = local.bucket_name
    Environment = "shared"
    ManagedBy   = "terraform"
  }
}

# バージョニング: 過去のstateにロールバックできるようにする
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 暗号化: stateにはAWSクレデンシャルが含まれる場合があるため必須
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# パブリックアクセス完全ブロック
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ステートロック用DynamoDBテーブル
# 複数人が同時にapplyするとstateが壊れるため、ロックで直列化する
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "handson-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "handson-tfstate-lock"
    Environment = "shared"
    ManagedBy   = "terraform"
  }
}
