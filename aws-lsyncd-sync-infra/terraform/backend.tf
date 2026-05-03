# =============================================================
# backend.tf — Terraform リモートバックエンド + プロバイダ設定
# S3 で tfstate を管理し、DynamoDB でロックを取得する。
# =============================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }

  # ★ 初回 apply 前に S3/DynamoDB を手動作成後、bucket 名を変更すること
  backend "s3" {
    bucket         = "YOUR_TFSTATE_BUCKET_NAME"
    key            = "aws-lsyncd-sync-infra/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "terraform-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aws-lsyncd-sync-infra"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}
