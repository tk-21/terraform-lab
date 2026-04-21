terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
  # S3バックエンド（適用時に -backend-config で上書き可能）
  backend "s3" {
    bucket = "REPLACE_WITH_YOUR_STATE_BUCKET"
    key    = "gaf/terraform.tfstate"
    region = "ap-northeast-1"
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
}

module "iam" {
  source               = "./modules/iam"
  name_prefix          = local.name_prefix
  aws_account_id       = var.aws_account_id
  raw_bucket_arn       = module.s3.raw_bucket_arn
  processed_bucket_arn = module.s3.processed_bucket_arn
  state_bucket_arn     = "arn:aws:s3:::${var.backend_bucket}"
}

module "firehose" {
  source            = "./modules/firehose"
  name_prefix       = local.name_prefix
  firehose_role_arn = module.iam.firehose_role_arn
  raw_bucket_arn    = module.s3.raw_bucket_arn
}

module "lambda_receiver" {
  source                = "./modules/lambda_receiver"
  name_prefix           = local.name_prefix
  receiver_role_arn     = module.iam.lambda_receiver_role_arn
  firehose_stream_name  = module.firehose.delivery_stream_name
  private_subnet_ids    = module.networking.private_subnet_ids
  sg_lambda_receiver_id = module.networking.sg_lambda_receiver_id
  alb_target_group_arn  = module.alb.target_group_arn
}

module "alb" {
  source              = "./modules/alb"
  name_prefix         = local.name_prefix
  public_subnet_ids   = module.networking.public_subnet_ids
  sg_alb_id           = module.networking.sg_alb_id
  lambda_receiver_arn = module.lambda_receiver.function_arn
}

module "global_accelerator" {
  source          = "./modules/global_accelerator"
  name_prefix     = local.name_prefix
  alb_arn         = module.alb.alb_arn
  raw_bucket_name = module.s3.raw_bucket_id
}

module "lambda_generator" {
  source                 = "./modules/lambda_generator"
  name_prefix            = local.name_prefix
  generator_role_arn     = module.iam.lambda_generator_role_arn
  scheduler_role_arn     = module.iam.scheduler_role_arn
  accelerator_endpoint   = "https://${module.global_accelerator.accelerator_dns_name}"
  private_subnet_ids     = module.networking.private_subnet_ids
  sg_lambda_generator_id = module.networking.sg_lambda_generator_id
}

module "databrew" {
  source                = "./modules/databrew"
  name_prefix           = local.name_prefix
  raw_bucket_name       = module.s3.raw_bucket_id
  processed_bucket_name = module.s3.processed_bucket_id
  databrew_role_arn     = module.iam.databrew_role_arn
}

module "glue" {
  source                = "./modules/glue"
  name_prefix           = local.name_prefix
  raw_bucket_name       = module.s3.raw_bucket_id
  processed_bucket_name = module.s3.processed_bucket_id
  athena_bucket_name    = module.s3.athena_results_bucket_id
}

module "observability" {
  source                         = "./modules/observability"
  name_prefix                    = local.name_prefix
  alb_arn_suffix                 = module.alb.alb_arn_suffix
  lambda_receiver_function_name  = module.lambda_receiver.function_name
  lambda_generator_function_name = module.lambda_generator.function_name
  firehose_stream_name           = module.firehose.delivery_stream_name
}
