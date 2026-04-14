terraform {
  required_version = "~> 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    archive = {
      # Lambda zip パッケージの生成に使用する
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"

  # 全リソースに共通タグを付与する。
  # コスト配分タグとして AWS Cost Explorer で集計できる。
  default_tags {
    tags = {
      Project     = "serverless-event-pipeline"
      ManagedBy   = "terraform"
      Environment = var.environment
      Owner       = "platform-team"
    }
  }
}
