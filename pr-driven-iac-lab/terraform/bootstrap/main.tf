terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

# TerraformステートファイルをチームとCI/CDで共有するためのS3バケット
# バージョニングを有効にすることでステートの破損時に過去バージョンへのロールバックが可能
resource "aws_s3_bucket" "tfstate" {
  bucket        = "tfstate-pr-driven-iac-lab-${var.aws_account_id}"
  force_destroy = true # ラボ用: destroy時にオブジェクトごと削除可能にする
}

# ステートファイルの変更履歴を保持し、誤上書きから保護する
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ステートファイルには機密情報が含まれるため、保存時暗号化を必須にする
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 意図しないパブリック公開を全項目でブロックし、ステート漏洩を防ぐ
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 複数人・複数CI/CDが同時にapplyしてステートが破損するのを防ぐ排他ロック用テーブル
# PAY_PER_REQUEST: ラボ環境ではアクセス頻度が低いためオンデマンドがコスト最適
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "tfstate-lock-pr-driven-iac-lab"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
