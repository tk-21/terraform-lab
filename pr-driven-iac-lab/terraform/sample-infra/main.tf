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

# AWSアカウントIDをデータソースから動的取得し、バケット名のグローバル一意性を確保する
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = "pr-driven-iac-lab"
    CostCenter  = "lab-01"
    LabRun      = "atlantis"
  }
}

# AtlantisとTFCがplan/applyする対象の実体。
# PRのたびにこのバケットの設定変更を提案し、PR-drivenワークフローを体験する
resource "aws_s3_bucket" "main" {
  bucket = "sample-infra-${var.environment}-${local.account_id}"

  tags = local.common_tags
}

# ステートバケットと同様、バージョニングでオブジェクト誤削除から保護する
resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 意図しない公開を防ぐ。デモ用バケットであっても公開アクセスは禁止
resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# EC2がS3バケットを読み取るためのIAMポリシー
# wildcard禁止: GetObject・ListBucketのみ許可し、このバケットのARNに限定する
resource "aws_iam_policy" "s3_reader" {
  name        = "sample-infra-s3-reader-policy-${var.environment}"
  description = "sample-infraバケットへの読み取り専用アクセスポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        # オブジェクトへのアクセスはバケットARN配下のみに限定
        Resource = "${aws_s3_bucket.main.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.main.arn
      }
    ]
  })

  tags = local.common_tags
}

# デモ用: EC2がS3バケットを読み取る想定のIAMロール
# ロール名は64文字以内のAWSハード制限に対応した命名にしている
resource "aws_iam_role" "s3_reader" {
  name        = "sample-infra-s3-reader-${var.environment}"
  description = "Demo role for EC2 to read the sample-infra bucket"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# ポリシーをロールにアタッチし、最小権限の原則を体現する
resource "aws_iam_role_policy_attachment" "s3_reader" {
  role       = aws_iam_role.s3_reader.name
  policy_arn = aws_iam_policy.s3_reader.arn
}
