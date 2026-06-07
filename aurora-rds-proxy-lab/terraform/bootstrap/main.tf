# Terraform State 管理用リソース
# ローカル State で bootstrap 自体を管理する（鶏卵問題を避けるため）
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "aurora-rds-proxy-lab"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

variable "aws_region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "リソース名プレフィックス（IAMロール名64文字制限対応）"
  type        = string
  default     = "arpl"
}

# Terraform State 保存用 S3 バケット
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.prefix}-tfstate-${data.aws_caller_identity.current.account_id}"

  # 誤削除防止: State バケットを誤って destroy しないよう保護
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      # AES256 で十分（KMS は追加コスト発生のため dev 環境では不使用）
      sse_algorithm = "AES256"
    }
  }
}

# パブリックアクセス完全ブロック（State ファイルに機密情報が含まれるため）
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State ロック用 DynamoDB テーブル
resource "aws_dynamodb_table" "tflock" {
  name         = "${var.prefix}-tflock"
  billing_mode = "PAY_PER_REQUEST" # コスト最適化: プロビジョンド不要
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

data "aws_caller_identity" "current" {}

output "tfstate_bucket" {
  description = "Terraform State 保存先 S3 バケット名"
  value       = aws_s3_bucket.tfstate.id
}

output "tflock_table" {
  description = "Terraform State ロック用 DynamoDB テーブル名"
  value       = aws_dynamodb_table.tflock.name
}

output "aws_account_id" {
  description = "デプロイ先 AWS アカウント ID"
  value       = data.aws_caller_identity.current.account_id
}
