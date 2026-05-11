# Terraform / プロバイダーバージョン固定
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # S3 バックエンド
  # 注意: バケット名は事前に手動作成が必要
  # aws s3 mb s3://ecl-tfstate-ACCOUNT_ID --region ap-northeast-1
  # aws dynamodb create-table --table-name ecl-tfstate-lock \
  #   --attribute-definitions AttributeName=LockID,AttributeType=S \
  #   --key-schema AttributeName=LockID,KeyType=HASH \
  #   --billing-mode PAY_PER_REQUEST --region ap-northeast-1
  backend "s3" {
    bucket         = "ecl-tfstate-REPLACE_ME" # account_id に置換
    key            = "ecs-chaos-lab/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "ecl-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ecs-chaos-lab"
      ManagedBy = "terraform"
    }
  }
}
