terraform {
  required_version = ">= 1.7"

  backend "s3" {
    # bootstrap で出力された bucket 名（arpl-tfstate-<ACCOUNT_ID>）に書き換える
    bucket         = "arpl-tfstate-XXXXXXXXXXXX"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "arpl-tflock"
    encrypt        = true
  }

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
