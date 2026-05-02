terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }

  backend "s3" {
    # Phase 1のbootstrap outputで取得した値を設定
    bucket         = "handson-dev-tfstate"      # terraform output tfstate_bucket_name
    key            = "handson/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "handson-dev-tflock"       # terraform output tflock_table_name
  }
}

provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = {
      Project     = "handson"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name_prefix = "handson-${var.environment}"
}

module "vpc" {
  source      = "../../modules/vpc"
  name_prefix = local.name_prefix
  aws_region  = "ap-northeast-1"
  vpc_cidr    = "10.0.0.0/16"
  az_count    = var.az_count
}

module "compute" {
  source             = "../../modules/compute"
  name_prefix        = local.name_prefix
  aws_region         = "ap-northeast-1"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  instance_type      = "t3.micro"
}

module "ssm" {
  source      = "../../modules/ssm"
  name_prefix = local.name_prefix
}
