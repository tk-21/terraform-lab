# Terraformバージョンとプロバイダー設定
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWSプロバイダー設定（全リソース共通タグをdefault_tagsで付与）
provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# VPCモジュール呼び出し
module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment
  azs         = ["ap-northeast-1a", "ap-northeast-1c"]
}

# セキュリティグループモジュール呼び出し
# ALB / App / Bastion の3種類のSGを管理
module "security_groups" {
  source = "../../modules/security_groups"

  project     = var.project
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
}

# EC2モジュール呼び出し
# IAM Role (SSM/CloudWatch)、App EC2×2、Bastion×1 を管理
module "ec2" {
  source = "../../modules/ec2"

  project             = var.project
  environment         = var.environment
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
  app_sg_id           = module.security_groups.app_sg_id
  bastion_sg_id       = module.security_groups.bastion_sg_id
}

# ALBモジュール呼び出し
# ALB本体、Target Group、Listener、TG Attachment を管理
module "alb" {
  source = "../../modules/alb"

  project           = var.project
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id         = module.security_groups.alb_sg_id
  app_instance_ids  = module.ec2.app_instance_ids
}

# CloudWatchモジュール呼び出し
# カスタムメトリクス・ログ収集・ダッシュボード・アラームを管理
module "cloudwatch" {
  source = "../../modules/cloudwatch"

  project                 = var.project
  environment             = var.environment
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  alert_email             = var.alert_email
}

# GitHub Actions OIDC モジュール
module "github_actions_oidc" {
  source = "../../modules/github_actions_oidc"

  project     = var.project
  environment = var.environment
  github_org  = "tk-21"
  github_repo = "terraform-lab"
}
