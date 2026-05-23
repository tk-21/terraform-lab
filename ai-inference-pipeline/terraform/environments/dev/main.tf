# ハンズオン用途のためlocalステートを使用
# 本番移行時はS3+DynamoDBに切り替える

terraform {
  required_version = ">= 1.6.0"
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
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Project   = "ai-inference-pipeline"
    Env       = var.env
    ManagedBy = "terraform"
  }
  name_prefix = "aip-${var.env}"
}

# 既存VPCのプライベートルートテーブルIDを取得
# Gateway型VPC Endpointはルートテーブルへのエントリとしてアタッチされるため必要
data "aws_route_tables" "private" {
  vpc_id = var.vpc_id
  filter {
    name   = "association.main"
    values = ["false"]
  }
}

module "vpc_endpoints" {
  source             = "../../modules/vpc_endpoints"
  name_prefix        = local.name_prefix
  vpc_id             = var.vpc_id
  vpc_cidr           = var.vpc_cidr
  region             = var.aws_region
  private_subnet_ids = var.private_subnet_ids
  route_table_ids    = data.aws_route_tables.private.ids
}

module "s3" {
  source      = "../../modules/s3"
  name_prefix = local.name_prefix
  account_id  = var.aws_account_id
}

module "dynamodb" {
  source      = "../../modules/dynamodb"
  name_prefix = local.name_prefix
}

module "ecr" {
  source      = "../../modules/ecr"
  env         = var.env
  name_prefix = local.name_prefix
}

module "iam" {
  source             = "../../modules/iam"
  name_prefix        = local.name_prefix
  region             = var.aws_region
  account_id         = var.aws_account_id
  input_bucket_arn   = module.s3.input_bucket_arn
  output_bucket_arn  = module.s3.output_bucket_arn
  dynamodb_table_arn = module.dynamodb.table_arn
  # phase5でSFNモジュールが作成されたため、EventBridge→SFN実行権限を有効化する
  sfn_arn = module.step_functions.state_machine_arn
  lambda_arns = [
    module.lambda.invoke_bedrock_arn,
    module.lambda.notify_chatwork_arn,
  ]
}

module "lambda" {
  source                  = "../../modules/lambda"
  name_prefix             = local.name_prefix
  env                     = var.env
  vpc_id                  = var.vpc_id
  private_subnet_ids      = var.private_subnet_ids
  lambda_bedrock_role_arn = module.iam.lambda_bedrock_role_arn
  lambda_notify_role_arn  = module.iam.lambda_notify_role_arn
  dynamodb_table_name     = module.dynamodb.table_name
  output_bucket_name      = module.s3.output_bucket_name
  chatwork_room_id        = var.chatwork_room_id
}

module "ecs" {
  source             = "../../modules/ecs"
  name_prefix        = local.name_prefix
  env                = var.env
  region             = var.aws_region
  vpc_id             = var.vpc_id
  execution_role_arn = module.iam.ecs_task_execution_role_arn
  task_role_arn      = module.iam.ecs_task_role_arn
  ecr_repository_url = module.ecr.repository_url
  input_bucket_name  = module.s3.input_bucket_name
  output_bucket_name = module.s3.output_bucket_name
}

module "eventbridge" {
  source               = "../../modules/eventbridge"
  name_prefix          = local.name_prefix
  input_bucket_name    = module.s3.input_bucket_name
  sfn_arn              = module.step_functions.state_machine_arn
  eventbridge_role_arn = module.iam.eventbridge_role_arn
}

module "step_functions" {
  source                = "../../modules/step_functions"
  name_prefix           = local.name_prefix
  env                   = var.env
  sfn_role_arn          = module.iam.sfn_role_arn
  ecs_cluster_arn       = module.ecs.cluster_arn
  task_definition_arn   = module.ecs.task_definition_arn
  private_subnet_ids    = var.private_subnet_ids
  ecs_security_group_id = module.ecs.ecs_security_group_id
  lambda_bedrock_arn    = module.lambda.invoke_bedrock_arn
  lambda_notify_arn     = module.lambda.notify_chatwork_arn
}
