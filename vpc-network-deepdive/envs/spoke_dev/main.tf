
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
  env    = "dev"
  prefix = "vnd-${local.env}"

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
  cidr_block = "10.2.0.0/16"
  create_igw = false # SpokeはIGW不要（NAT GWも不使用）

  subnets = {
    # Spokeはプライベートサブネットのみ
    # インターネットアクセスはInterface Endpoint経由（SSM等）
    "private-1a" = { cidr = "10.2.10.0/24", az = "ap-northeast-1a" }
    "private-1c" = { cidr = "10.2.11.0/24", az = "ap-northeast-1c" }
  }

  tags = local.common_tags
}
