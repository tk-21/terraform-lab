terraform {
  required_version = ">= 1.5.0"

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
}

module "networking" {
  source = "./modules/networking"

  project              = local.project
  environment          = local.environment
  vpc_cidr             = var.vpc_cidr
  private_subnet_cidrs = var.private_subnet_cidrs
  common_tags          = local.common_tags
}

module "sqs" {
  source = "./modules/sqs"

  project     = local.project
  environment = local.environment
  common_tags = local.common_tags
}

module "lambda" {
  source = "./modules/lambda"

  project             = local.project
  environment         = local.environment
  common_tags         = local.common_tags
  dynamodb_table_name = aws_dynamodb_table.orders.name
  dynamodb_table_arn  = aws_dynamodb_table.orders.arn
  orders_queue_arn    = module.sqs.orders_queue_arn
  orders_dlq_arn      = module.sqs.orders_dlq_arn
  private_subnet_ids  = module.networking.private_subnet_ids
  vpc_endpoints_sg_id = module.networking.vpc_endpoints_sg_id
  vpc_id              = module.networking.vpc_id
}

module "ecs" {
  source = "./modules/ecs"

  project             = local.project
  environment         = local.environment
  common_tags         = local.common_tags
  private_subnet_ids  = module.networking.private_subnet_ids
  vpc_id              = module.networking.vpc_id
  dynamodb_table_name = aws_dynamodb_table.orders.name
  dynamodb_table_arn  = aws_dynamodb_table.orders.arn
  vpc_endpoints_sg_id = module.networking.vpc_endpoints_sg_id
}

module "step_functions" {
  source = "./modules/step_functions"

  project             = local.project
  environment         = local.environment
  common_tags         = local.common_tags
  inventory_check_arn = module.lambda.inventory_check_arn
  notification_arn    = module.lambda.notification_arn
  ecs_cluster_arn     = module.ecs.ecs_cluster_arn
  task_definition_arn = module.ecs.task_definition_arn
  ecs_task_sg_id      = module.ecs.ecs_task_sg_id
  private_subnet_ids  = module.networking.private_subnet_ids
  dynamodb_table_name = aws_dynamodb_table.orders.name
  dynamodb_table_arn  = aws_dynamodb_table.orders.arn
  orders_queue_arn    = module.sqs.orders_queue_arn
}

module "monitoring" {
  source = "./modules/monitoring"

  project                  = local.project
  common_tags              = local.common_tags
  state_machine_arn        = module.step_functions.state_machine_arn
  state_machine_name       = module.step_functions.state_machine_name
  inventory_check_function = module.lambda.inventory_check_function_name
  notification_function    = module.lambda.notification_function_name
  dlq_reprocessor_function = module.lambda.dlq_reprocessor_function_name
  sfn_trigger_function     = module.step_functions.sfn_trigger_function_name
  orders_queue_name        = module.sqs.orders_queue_name
  orders_dlq_name          = module.sqs.orders_dlq_name
  ecs_cluster_name         = module.ecs.ecs_cluster_name
  dynamodb_table_name      = aws_dynamodb_table.orders.name
}

# DynamoDB: 注文ステータス管理テーブル
resource "aws_dynamodb_table" "orders" {
  name         = "${local.project}-orders"
  billing_mode = "PAY_PER_REQUEST" # なぜ: 負荷が不定のためオンデマンド課金を選択
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = "status-created_at-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  # なぜ: 本番移行時のデータ保護。dev環境でも習慣として有効化
  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.project}-orders"
  })
}
