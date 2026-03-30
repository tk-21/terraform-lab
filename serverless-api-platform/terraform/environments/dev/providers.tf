# terraform/environments/dev/providers.tf
#
# Terraform バージョン制約とプロバイダ設定。
# CLAUDE.md の要件: terraform ~> 1.7、aws ~> 5.50

terraform {
  required_version = "~> 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    # archive プロバイダは Lambda デプロイパッケージ (zip) の生成に使用
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    # random プロバイダはリソース名のサフィックス生成などに使用
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# AWS プロバイダ設定
# default_tags を使用することで、全リソースに共通タグを自動付与する。
# 個別リソースに tags = {} を書く必要がなくなり、タグの漏れを防ぐ。
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
