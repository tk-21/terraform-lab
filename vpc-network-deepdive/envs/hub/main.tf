
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = local.common_tags
  }
}

locals {
  env    = "hub"
  prefix = "vnd-${local.env}"

  # 全リソースに付与する共通タグ
  common_tags = {
    Project     = "vpc-network-deepdive"
    ManagedBy   = "terraform"
    Environment = local.env
    CostTarget  = "learning"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  prefix     = local.prefix
  cidr_block = "10.0.0.0/16"
  create_igw = true # HubはIGWを持つ（Spoke向けサービス公開の将来拡張用）

  subnets = {
    # 今回は未使用だが、将来のALB/Bastion配置を想定して確保
    "public-1a" = { cidr = "10.0.0.0/24", az = "ap-northeast-1a", public = true }
    "public-1c" = { cidr = "10.0.1.0/24", az = "ap-northeast-1c", public = true }

    # Interface EndpointとNLBを配置するプライベートサブネット
    "private-1a" = { cidr = "10.0.10.0/24", az = "ap-northeast-1a" }
    "private-1c" = { cidr = "10.0.11.0/24", az = "ap-northeast-1c" }
  }

  tags = local.common_tags
}
