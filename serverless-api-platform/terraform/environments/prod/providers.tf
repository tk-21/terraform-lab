# terraform/environments/prod/providers.tf
#
# prod 環境のプロバイダ設定。dev と同一。

terraform {
  required_version = "~> 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "serverless-api-platform"
      ManagedBy   = "terraform"
      Environment = var.environment
      Owner       = "platform-team"
    }
  }
}
