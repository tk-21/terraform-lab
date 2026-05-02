provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = {
      Project     = "secure-3tier-iac-pipeline"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

locals {
  common_tags = {
    Project     = "secure-3tier-iac-pipeline"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

# ---------------------------------------------------------------------------
# Phase 1: ネットワーク基盤
# ---------------------------------------------------------------------------
module "network" {
  source = "../../modules/network"

  environment          = var.environment
  owner                = var.owner
  vpc_cidr             = "172.16.0.0/16"
  azs                  = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
  public_subnet_cidrs  = ["172.16.0.0/24", "172.16.1.0/24", "172.16.2.0/24"]
  private_subnet_cidrs = ["172.16.10.0/24", "172.16.11.0/24", "172.16.12.0/24"]
  data_subnet_cidrs    = ["172.16.20.0/24", "172.16.21.0/24", "172.16.22.0/24"]
}

# ---------------------------------------------------------------------------
# Phase 2: KMS CMK + Secrets Manager (kms.tf / secrets_manager.tf に直接定義)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Phase 2: セキュリティ層 (IAM / SG)
# ---------------------------------------------------------------------------
module "security" {
  source = "../../modules/security"

  environment = var.environment
  owner       = var.owner
  vpc_id      = module.network.vpc_id
  kms_key_arn = aws_kms_key.main.arn
  common_tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Phase 2: コンピュート層 (ALB / Launch Template / ASG)
# ---------------------------------------------------------------------------
module "compute" {
  source = "../../modules/compute"

  environment               = var.environment
  owner                     = var.owner
  vpc_id                    = module.network.vpc_id
  public_subnet_ids         = module.network.public_subnet_ids
  private_subnet_ids        = module.network.private_subnet_ids
  alb_sg_id                 = module.security.alb_sg_id
  ec2_sg_id                 = module.security.ec2_sg_id
  ec2_instance_profile_name = module.security.ec2_instance_profile_name
  kms_key_arn               = aws_kms_key.main.arn
  certificate_arn           = var.acm_certificate_arn
  enable_https              = var.enable_https
  common_tags               = local.common_tags
}

# ---------------------------------------------------------------------------
# Phase 3: データ層 (RDS Aurora MySQL Serverless v2)
# ---------------------------------------------------------------------------
module "database" {
  source = "../../modules/database"

  environment     = var.environment
  owner           = var.owner
  data_subnet_ids = module.network.data_subnet_ids
  rds_sg_id       = module.security.rds_sg_id
  kms_key_arn     = aws_kms_key.main.arn
  rds_secret_arn  = aws_secretsmanager_secret.rds_master.arn
  common_tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Phase 3: SSM Session Manager 設定 + Parameter Store
# ---------------------------------------------------------------------------
module "ssm" {
  source = "../../modules/ssm"

  environment              = var.environment
  owner                    = var.owner
  kms_key_arn              = aws_kms_key.main.arn
  session_logs_bucket_name = module.security.session_logs_bucket_name
  cluster_endpoint         = module.database.cluster_endpoint
  reader_endpoint          = module.database.reader_endpoint
  port                     = module.database.port
  common_tags              = local.common_tags
}
