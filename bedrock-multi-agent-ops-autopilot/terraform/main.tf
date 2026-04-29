terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
  # S3バックエンド（本番環境では有効化）
  # backend "s3" {
  #   bucket = "tfstate-bmao-{account_id}"
  #   key    = "bedrock-multi-agent-ops-autopilot/terraform.tfstate"
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
  environment = local.environment
  account_id  = local.account_id
  common_tags = local.common_tags
}

module "lambda" {
  source = "./modules/lambda"

  prefix      = local.prefix
  environment = local.environment
  account_id  = local.account_id
  common_tags = local.common_tags

  lambda_base_role_arn                  = module.foundation.lambda_base_role_arn
  dynamodb_execution_history_table_name = module.foundation.dynamodb_execution_history_table_name
  dynamodb_approval_requests_table_name = module.foundation.dynamodb_approval_requests_table_name
  s3_reports_bucket_name                = module.foundation.s3_reports_bucket_name
}

module "agents" {
  source = "./modules/agents"

  prefix      = local.prefix
  environment = local.environment
  account_id  = local.account_id
  common_tags = local.common_tags

  incident_investigator_function_arn = module.lambda.incident_investigator_function_arn
  cost_optimizer_function_arn        = module.lambda.cost_optimizer_function_arn
  remediation_function_arn           = module.lambda.remediation_function_arn
  reporter_function_arn              = module.lambda.reporter_function_arn
  supervisor_agent_role_arn          = module.foundation.supervisor_agent_role_arn
}

module "stepfunctions" {
  source = "./modules/stepfunctions"

  prefix      = local.prefix
  environment = local.environment
  account_id  = local.account_id
  common_tags = local.common_tags

  execution_history_table_name = module.foundation.dynamodb_execution_history_table_name
  execution_history_table_arn  = module.foundation.dynamodb_execution_history_table_arn
  cloudwatch_log_group_arn     = module.foundation.cloudwatch_log_group_stepfunctions_arn

  supervisor_agent_id       = module.agents.supervisor_agent_id
  supervisor_agent_alias_id = module.agents.supervisor_agent_alias_id

  alert_threshold_cost_usd = var.alert_threshold_cost_usd
}
