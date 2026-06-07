# Phase 1: VPC・サブネット・VPC Endpoint 構築
module "networking" {
  source     = "../../modules/networking"
  prefix     = var.prefix
  aws_region = var.aws_region
  vpc_cidr   = var.vpc_cidr
}

# Phase 2: Aurora Serverless v2 構築
module "aurora" {
  source = "../../modules/aurora"

  prefix        = var.prefix
  vpc_id        = module.networking.vpc_id
  db_subnet_ids = module.networking.private_db_subnet_ids
  aws_region    = var.aws_region

  # Phase 3 で RDS Proxy SG に差し替える（暫定: VPC Endpoint SG で代用）
  app_sg_id = module.networking.vpc_endpoint_sg_id
}

# Phase 3: RDS Proxy + IAM 認証
data "aws_caller_identity" "current" {}

module "rds_proxy" {
  source = "../../modules/rds-proxy"

  prefix             = var.prefix
  vpc_id             = module.networking.vpc_id
  db_subnet_ids      = module.networking.private_db_subnet_ids
  aurora_sg_id       = module.aurora.aurora_sg_id
  cluster_id         = module.aurora.cluster_id
  cluster_endpoint   = module.aurora.cluster_endpoint
  reader_endpoint    = module.aurora.cluster_reader_endpoint
  master_secret_arn  = module.aurora.master_secret_arn
  db_master_username = module.aurora.db_master_username
  aws_region         = var.aws_region
  aws_account_id     = data.aws_caller_identity.current.account_id
}

# Phase 5: ECS Fargate アプリケーション + ALB
module "ecs_app" {
  source = "../../modules/ecs-app"

  prefix                     = var.prefix
  aws_region                 = var.aws_region
  aws_account_id             = data.aws_caller_identity.current.account_id
  vpc_id                     = module.networking.vpc_id
  public_subnet_ids          = module.networking.public_subnet_ids
  private_app_subnet_ids     = module.networking.private_app_subnet_ids
  proxy_sg_id                = module.rds_proxy.proxy_sg_id
  vpc_endpoint_sg_id         = module.networking.vpc_endpoint_sg_id
  app_rds_connect_policy_arn = module.rds_proxy.app_rds_connect_policy_arn
  ecr_image_uri              = var.ecr_image_uri
  github_org                 = var.github_org
  github_repo                = var.github_repo
}

# Phase 4: Secrets Manager ローテーション + Chatwork 通知
module "secrets" {
  source = "../../modules/rotation"

  prefix         = var.prefix
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id

  # Aurora 直接接続用（ローテーション Lambda が IAM 認証不要の直接接続でパスワード変更）
  aurora_sg_id      = module.aurora.aurora_sg_id
  master_secret_arn = module.aurora.master_secret_arn
  cluster_endpoint  = module.aurora.cluster_endpoint
  cluster_id        = module.aurora.cluster_id

  chatwork_room_id       = var.chatwork_room_id
  vpc_id                 = module.networking.vpc_id
  private_app_subnet_ids = module.networking.private_app_subnet_ids
  vpc_endpoint_sg_id     = module.networking.vpc_endpoint_sg_id
  vpc_cidr               = var.vpc_cidr
}
