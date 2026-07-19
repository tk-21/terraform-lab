terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# メインリージョン: ap-northeast-1 (東京)
provider "aws" {
  region = var.region
}

# Lambda@Edge・WAF CloudFront スコープは us-east-1 が必須
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}
