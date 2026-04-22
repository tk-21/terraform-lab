terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  backend "s3" {
    # placeholder: var は backend ブロックで使用不可のため直接記述
    # bucket = "<your-terraform-state-bucket>"
    # key    = "vpc-lattice-msk-flink/terraform.tfstate"
    # region = "ap-northeast-1"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

module "networking" {
  source      = "./modules/networking"
  name_prefix = local.name_prefix
}

module "s3" {
  source         = "./modules/s3"
  name_prefix    = local.name_prefix
  aws_account_id = var.aws_account_id
  tags           = local.common_tags

  depends_on = [module.networking]
}

module "iam" {
  source               = "./modules/iam"
  name_prefix          = local.name_prefix
  aws_account_id       = var.aws_account_id
  aws_region           = var.aws_region
  output_bucket_arn    = module.s3.output_bucket_arn
  flink_app_bucket_arn = module.s3.flink_app_bucket_arn
  tags                 = local.common_tags

  depends_on = [module.s3]
}

module "msk" {
  source          = "./modules/msk"
  name_prefix     = local.name_prefix
  subnet_ids      = module.networking.private_subnet_ids
  sg_msk_id       = module.networking.sg_msk_id
  lambda_role_arn = module.iam.producer_role_arn
  flink_role_arn  = module.iam.flink_role_arn
  tags            = local.common_tags

  depends_on = [module.iam]
}

module "lambda_producer" {
  source                = "./modules/lambda_producer"
  name_prefix           = local.name_prefix
  lambda_role_arn       = module.iam.producer_role_arn
  msk_bootstrap_brokers = module.msk.msk_bootstrap_brokers_sasl_iam
  subnet_ids            = module.networking.private_subnet_ids
  sg_lambda_id          = module.networking.sg_lambda_id
  tags                  = local.common_tags

  depends_on = [module.msk]
}

module "vpc_lattice" {
  source            = "./modules/vpc_lattice"
  name_prefix       = local.name_prefix
  vpc_id            = module.networking.vpc_id
  sg_vpc_lattice_id = module.networking.sg_vpc_lattice_id
  lambda_role_arn   = module.iam.producer_role_arn
  flink_role_arn    = module.iam.flink_role_arn
  tags              = local.common_tags

  depends_on = [module.msk]
}

module "flink" {
  source                = "./modules/flink"
  name_prefix           = local.name_prefix
  flink_role_arn        = module.iam.flink_role_arn
  flink_app_bucket_arn  = module.s3.flink_app_bucket_arn
  flink_app_bucket_name = module.s3.flink_app_bucket_name
  output_bucket_name    = module.s3.output_bucket_name
  msk_bootstrap_brokers = module.msk.msk_bootstrap_brokers_sasl_iam
  private_subnet_ids    = module.networking.private_subnet_ids
  sg_flink_id           = module.networking.sg_flink_id
  tags                  = local.common_tags

  depends_on = [module.msk, module.vpc_lattice]
}

module "glue" {
  source             = "./modules/glue"
  name_prefix        = local.name_prefix
  output_bucket_name = module.s3.output_bucket_name
  tags               = local.common_tags

  depends_on = [module.s3]
}

module "observability" {
  source                   = "./modules/observability"
  name_prefix              = local.name_prefix
  aws_region               = var.aws_region
  msk_cluster_name         = module.msk.msk_cluster_name
  lambda_function_name     = module.lambda_producer.lambda_function_name
  flink_app_name           = module.flink.application_name
  vpc_lattice_service_name = module.vpc_lattice.service_id
  tags                     = local.common_tags

  depends_on = [module.flink, module.lambda_producer, module.vpc_lattice]
}
