# ブートストラップ: このコードだけはローカルstateで管理する
# 理由: tfstate管理用リソース自体をremote stateで管理すると鶏と卵になるため

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # ここだけlocal backend（意図的）
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# tfstate保存用S3バケット
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-${var.environment}-tfstate"

  # 誤削除防止: terraform destroyしてもバケットを消さない
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled" # stateのバージョン管理でロールバック可能にする
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # stateにはシークレット情報が含まれるため暗号化必須
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDBロックテーブル
resource "aws_dynamodb_table" "tflock" {
  name         = "${var.project}-${var.environment}-tflock"
  billing_mode = "PAY_PER_REQUEST" # ハンズオン用: 固定費ゼロ
  hash_key     = "LockID"         # Terraformが要求する固定キー名

  attribute {
    name = "LockID"
    type = "S"
  }
}
