terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aws-multilayer-firewall-terraform"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "takuya"
    }
  }
}

# -------------------------------------------------------------------
# VPC モジュール
# -------------------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  prefix      = var.prefix
  environment = var.environment
}

# -------------------------------------------------------------------
# Security Group モジュール
# -------------------------------------------------------------------
module "security_group" {
  source = "../../modules/security_group"

  prefix      = var.prefix
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
}

# -------------------------------------------------------------------
# NACL モジュール
# -------------------------------------------------------------------
module "nacl" {
  source = "../../modules/nacl"

  prefix             = var.prefix
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
}

# -------------------------------------------------------------------
# Network Firewall モジュール
# -------------------------------------------------------------------
module "network_firewall" {
  source = "../../modules/network_firewall"

  prefix                = var.prefix
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  firewall_subnet_id_1a = module.vpc.firewall_subnet_ids["1a"]
  public_subnet_ids     = module.vpc.public_subnet_ids
  public_subnet_cidrs   = module.vpc.public_subnet_cidrs
  internet_gateway_id   = module.vpc.internet_gateway_id
  public_route_table_id = module.vpc.public_route_table_id
}

# -------------------------------------------------------------------
# ALB モジュール（Phase 3: WAF アタッチ先）
# -------------------------------------------------------------------
module "alb" {
  source = "../../modules/alb"

  prefix            = var.prefix
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  sg_id             = module.security_group.web_sg_id
}

# -------------------------------------------------------------------
# WAF モジュール（Phase 3: L7 多層防御）
# -------------------------------------------------------------------
module "waf" {
  source = "../../modules/waf"

  prefix          = var.prefix
  alb_arn         = module.alb.alb_arn
  blocked_ip_list = var.blocked_ip_list
}

# -------------------------------------------------------------------
# EC2 SSM モジュール
# -------------------------------------------------------------------
module "ec2_ssm" {
  source = "../../modules/ec2_ssm"

  prefix            = var.prefix
  environment       = var.environment
  subnet_id         = module.vpc.private_subnet_ids["1a"]
  security_group_id = module.security_group.ssm_sg_id
}
