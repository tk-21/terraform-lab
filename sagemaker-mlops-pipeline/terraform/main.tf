terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
  # S3バックエンド（本番環境では有効化）
  # backend "s3" {
  #   bucket = "tfstate-smp-{account_id}"
  #   key    = "sagemaker-mlops-pipeline/terraform.tfstate"
  #   region = "ap-northeast-1"
  # }
}

provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "foundation" {
  source = "./modules/foundation"

  prefix      = local.prefix
  account_id  = local.account_id
  region      = local.region
  common_tags = local.common_tags

  model_approval_threshold = var.model_approval_threshold
}

module "pipeline" {
  source = "./modules/pipeline"

  prefix            = local.prefix
  pipeline_role_arn = module.foundation.pipeline_role_arn
  common_tags       = local.common_tags
}

# endpointモジュールはregistryモジュールより先に作成（registryがCodePipeline ARNを参照するため）
module "endpoint" {
  source = "./modules/endpoint"

  prefix                 = local.prefix
  account_id             = local.account_id
  region                 = local.region
  common_tags            = local.common_tags
  artifacts_bucket_name  = module.foundation.artifacts_bucket_name
  endpoint_role_arn      = module.foundation.endpoint_role_arn
  endpoint_instance_type = var.endpoint_instance_type
  endpoint_model_name    = var.endpoint_model_name
}

module "registry" {
  source = "./modules/registry"

  prefix                            = local.prefix
  account_id                        = local.account_id
  region                            = local.region
  common_tags                       = local.common_tags
  artifacts_bucket_name             = module.foundation.artifacts_bucket_name
  codepipeline_arn                  = module.endpoint.codepipeline_arn
  eventbridge_codepipeline_role_arn = module.endpoint.eventbridge_codepipeline_role_arn
  powertools_layer_version          = var.powertools_layer_version
}

module "monitor" {
  source = "./modules/monitor"

  prefix                   = local.prefix
  account_id               = local.account_id
  region                   = local.region
  common_tags              = local.common_tags
  pipeline_role_arn        = module.foundation.pipeline_role_arn
  artifacts_bucket_name    = module.foundation.artifacts_bucket_name
  data_bucket_name         = module.foundation.data_bucket_name
  endpoint_name            = coalesce(module.endpoint.endpoint_name, "")
  endpoint_instance_type   = var.endpoint_instance_type
  endpoint_model_name      = var.endpoint_model_name
  powertools_layer_version = var.powertools_layer_version
}
