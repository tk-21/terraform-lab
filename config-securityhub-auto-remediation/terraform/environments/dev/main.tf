terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id

  common_tags = {
    Project     = "config-securityhub-auto-remediation"
    Environment = var.environment
    ManagedBy   = "terraform"
    CostCenter  = "security-automation"
  }
}

module "networking" {
  source = "../../modules/networking"

  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
}

module "audit" {
  source = "../../modules/audit"

  environment    = var.environment
  aws_account_id = local.aws_account_id
}

module "iam" {
  source = "../../modules/iam"

  environment    = var.environment
  aws_account_id = local.aws_account_id
  audit_bucket   = module.audit.audit_bucket_name
  dlq_arn        = module.audit.dlq_arn
}

module "remediation" {
  source = "../../modules/remediation"

  environment         = var.environment
  lambda_role_arn     = module.iam.lambda_remediation_role_arn
  subnet_ids          = module.networking.private_subnet_ids
  lambda_sg_id        = module.networking.lambda_security_group_id
  dynamodb_table_name = module.audit.dynamodb_table_name
  audit_bucket_name   = module.audit.audit_bucket_name
  dlq_arn             = module.audit.dlq_arn
  common_tags         = local.common_tags

  # Config Rule用EventBridgeルールARN (configモジュールから取得)
  s3_config_rule_event_rule_arn  = module.config.s3_noncompliant_rule_arn
  iam_config_rule_event_rule_arn = module.config.iam_noncompliant_rule_arn
  sg_config_rule_event_rule_arn  = module.config.sg_noncompliant_rule_arn
  rds_config_rule_event_rule_arn = module.config.rds_noncompliant_rule_arn

  # Security Hub Custom Action用EventBridgeルールARN (security_hubモジュールから取得)
  s3_custom_action_event_rule_arn  = module.security_hub.s3_custom_action_rule_arn
  iam_custom_action_event_rule_arn = module.security_hub.iam_custom_action_rule_arn
  sg_custom_action_event_rule_arn  = module.security_hub.sg_custom_action_rule_arn
  rds_custom_action_event_rule_arn = module.security_hub.rds_custom_action_rule_arn
}

module "config" {
  source = "../../modules/config"

  config_service_role_arn     = module.iam.config_service_role_arn
  audit_bucket_name           = module.audit.audit_bucket_name
  dlq_arn                     = module.audit.dlq_arn
  eventbridge_invoke_role_arn = module.iam.eventbridge_invoke_role_arn

  s3_remediation_lambda_arn  = module.remediation.s3_lambda_arn
  iam_remediation_lambda_arn = module.remediation.iam_lambda_arn
  sg_remediation_lambda_arn  = module.remediation.sg_lambda_arn
  rds_remediation_lambda_arn = module.remediation.rds_lambda_arn
}

module "dashboard" {
  source = "../../modules/dashboard"

  environment    = var.environment
  dlq_queue_name = module.audit.dlq_queue_name
}

module "security_hub" {
  source = "../../modules/security_hub"

  environment = var.environment
  dlq_arn     = module.audit.dlq_arn

  s3_remediation_lambda_arn  = module.remediation.s3_lambda_arn
  iam_remediation_lambda_arn = module.remediation.iam_lambda_arn
  sg_remediation_lambda_arn  = module.remediation.sg_lambda_arn
  rds_remediation_lambda_arn = module.remediation.rds_lambda_arn
}
