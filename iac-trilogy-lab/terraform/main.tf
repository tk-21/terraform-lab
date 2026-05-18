terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"

  # 全リソースにデフォルトタグを付与
  # リソース個別の tags と merge されるため、共通タグの書き漏れを防ぐ
  default_tags {
    tags = local.common_tags
  }
}
