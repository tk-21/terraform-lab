terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # S3 バックエンド設定
  # bucket 名は account_id を含むため変数が使えない。
  # デプロイ前に "999828867039" を実際の AWS アカウント ID に置換すること。
  # 例: cel-tfstate-123456789012
  backend "s3" {
    bucket         = "cel-tfstate-999828867039"
    key            = "chaos-engineering-lab/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "chaos-engineering-lab"
      Env       = "dev"
      ManagedBy = "terraform"
    }
  }
}
