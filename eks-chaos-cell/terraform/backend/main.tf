# =============================================================
# Terraform Backend リソース
# S3（tfstate）+ DynamoDB（ロック）+ GitHub Actions OIDC
# 一度だけ手動applyする
# =============================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.aws_region }

# --- S3バケット ---
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${var.aws_account_id}"
  lifecycle { prevent_destroy = true }
  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- DynamoDB ロックテーブル ---
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "${var.project_name}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  tags = local.common_tags
}

# --- GitHub Actions OIDC Provider ---
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = local.common_tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? (
    aws_iam_openid_connect_provider.github[0].arn
  ) : "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"

  common_tags = {
    Project     = var.project_name
    Environment = "mgmt"
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

# --- GitHub Actions IAMロール ---
# 命名: ecc-gha-role（eks-chaos-cell-github-actions-role を短縮）
resource "aws_iam_role" "github_actions" {
  name = "ecc-gha-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" : "repo:${var.github_org}/${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "github_actions" {
  name = "ecc-gha-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # tfstate 読み書き
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
      },
      # DynamoDB ロック
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.tfstate_lock.arn
      },
      # terraform plan に必要な読み取り権限
      {
        Effect = "Allow"
        Action = [
          "eks:Describe*", "eks:List*",
          "ec2:Describe*",
          "iam:Get*", "iam:List*",
          "kms:Describe*", "kms:List*"
        ]
        Resource = "*"
      }
    ]
  })
}
