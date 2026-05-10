locals {
  # 共通タグ（全モジュールに渡す）
  common_tags = {
    Project   = var.project
    Env       = var.env
    ManagedBy = "terraform"
  }
}

# ── Phase 1: ネットワーク基盤 ──────────────────────────────────────

# VPC・サブネット・IGW・NAT GW を構築する
module "vpc" {
  source = "../../modules/vpc"

  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  prefix               = var.prefix
  env                  = var.env
  tags                 = local.common_tags
}

# ALB 用・EC2 用セキュリティグループを構築する
module "sg" {
  source = "../../modules/sg"

  vpc_id = module.vpc.vpc_id
  prefix = var.prefix
  env    = var.env
  tags   = local.common_tags

  depends_on = [module.vpc]
}

# ── Phase 2: ALB + ASG ─────────────────────────────────────────────

# Application Load Balancer・ターゲットグループ・アクセスログ S3 を構築する
module "alb" {
  source = "../../modules/alb"

  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id         = module.sg.alb_sg_id
  prefix            = var.prefix
  env               = var.env
  account_id        = var.account_id
  tags              = local.common_tags

  depends_on = [module.sg]
}

# Launch Template + Auto Scaling Group + Target Tracking Policy を構築する
module "asg" {
  source = "../../modules/asg"

  prefix                = var.prefix
  env                   = var.env
  private_subnet_ids    = module.vpc.private_subnet_ids
  ec2_sg_id             = module.sg.ec2_sg_id
  target_group_arn      = module.alb.target_group_arn
  min_size              = var.asg_min_size
  max_size              = var.asg_max_size
  desired_capacity      = var.asg_desired_capacity
  instance_profile_name = module.iam.instance_profile_name
  tags                  = local.common_tags

  depends_on = [module.alb, module.iam]
}

# ── Phase 3: IAM + FIS ─────────────────────────────────────────────

# FIS 実行ロールと EC2 インスタンスプロファイルを構築する
module "iam" {
  source = "../../modules/iam"

  prefix = var.prefix
  env    = var.env
  tags   = local.common_tags
}

# FIS 実験テンプレートと CloudWatch 停止条件アラームを構築する
module "fis" {
  source = "../../modules/fis"

  prefix       = var.prefix
  env          = var.env
  fis_role_arn = module.iam.fis_role_arn
  asg_name     = module.asg.asg_name
  tags         = local.common_tags

  depends_on = [module.asg, module.iam]
}
