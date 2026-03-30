# terraform/environments/prod/main.tf
#
# prod 環境のルートモジュール。
# dev との主な差異:
#   - enable_pitr = true（DynamoDB ポイントインタイムリカバリ有効）
#   - enable_dax = true（DAX によるキャッシュ）
#   - enable_waf = true（WAF によるレートリミット・IP制限）
#   - cognito_user_pool_arn を設定（Cognito 認証有効）

locals {
  prefix              = "${var.project}-${var.environment}"
  lambda_runtime      = "python3.12"
  lambda_architecture = ["arm64"]
  lambda_timeout      = 25
}

module "dynamodb" {
  source      = "../../modules/dynamodb"
  prefix      = local.prefix
  environment = var.environment
  # prod では PITR と DAX を有効化
  enable_pitr = true
  enable_dax  = true
}

module "iam" {
  source             = "../../modules/iam"
  prefix             = local.prefix
  environment        = var.environment
  account_id         = var.account_id
  dynamodb_table_arn = module.dynamodb.table_arn
  audit_bucket_arn   = module.storage.audit_bucket_arn
}

module "storage" {
  source      = "../../modules/storage"
  prefix      = local.prefix
  environment = var.environment
  account_id  = var.account_id
}

module "lambda_list_items" {
  source        = "../../modules/lambda-function"
  function_name = "${local.prefix}-list-items"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/list_items"
  environment_variables = {
    DYNAMODB_TABLE_NAME     = module.dynamodb.table_name
    ENVIRONMENT             = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-list-items"
  }
  execution_role_arn = module.iam.lambda_role_arns["list-items"]
  # prod では長めにログを保持
  log_retention_days = 90
}

module "lambda_get_item" {
  source        = "../../modules/lambda-function"
  function_name = "${local.prefix}-get-item"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/get_item"
  environment_variables = {
    DYNAMODB_TABLE_NAME     = module.dynamodb.table_name
    ENVIRONMENT             = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-get-item"
  }
  execution_role_arn = module.iam.lambda_role_arns["get-item"]
  log_retention_days = 90
}

module "lambda_create_item" {
  source        = "../../modules/lambda-function"
  function_name = "${local.prefix}-create-item"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/create_item"
  environment_variables = {
    DYNAMODB_TABLE_NAME     = module.dynamodb.table_name
    ENVIRONMENT             = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-create-item"
  }
  execution_role_arn = module.iam.lambda_role_arns["create-item"]
  log_retention_days = 90
}

module "lambda_update_item" {
  source        = "../../modules/lambda-function"
  function_name = "${local.prefix}-update-item"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/update_item"
  environment_variables = {
    DYNAMODB_TABLE_NAME     = module.dynamodb.table_name
    ENVIRONMENT             = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-update-item"
  }
  execution_role_arn = module.iam.lambda_role_arns["update-item"]
  log_retention_days = 90
}

module "lambda_delete_item" {
  source        = "../../modules/lambda-function"
  function_name = "${local.prefix}-delete-item"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/delete_item"
  environment_variables = {
    DYNAMODB_TABLE_NAME     = module.dynamodb.table_name
    ENVIRONMENT             = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-delete-item"
  }
  execution_role_arn = module.iam.lambda_role_arns["delete-item"]
  log_retention_days = 90
}

module "lambda_stream_processor" {
  source        = "../../modules/lambda-function"
  function_name = "${local.prefix}-stream-processor"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = 60
  source_dir    = "${path.root}/../../../src/stream_processor"
  environment_variables = {
    AUDIT_BUCKET_NAME       = module.storage.audit_bucket_name
    ENVIRONMENT             = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-stream-processor"
  }
  execution_role_arn = module.iam.lambda_role_arns["stream-processor"]
  event_source_arn   = module.dynamodb.stream_arn
  log_retention_days = 90
}

module "api_gateway" {
  source      = "../../modules/api-gateway"
  prefix      = local.prefix
  environment = var.environment
  # prod では WAF を有効化
  enable_waf  = true
  allowed_ips = var.allowed_ips
  lambda_arns = {
    list_items  = module.lambda_list_items.function_arn
    get_item    = module.lambda_get_item.function_arn
    create_item = module.lambda_create_item.function_arn
    update_item = module.lambda_update_item.function_arn
    delete_item = module.lambda_delete_item.function_arn
  }
  # TODO: cognito モジュール追加後に有効化
  cognito_user_pool_arn = null
}

module "monitoring" {
  source      = "../../modules/monitoring"
  prefix      = local.prefix
  environment = var.environment
  alert_email = var.alert_email
  lambda_function_names = [
    module.lambda_list_items.function_name,
    module.lambda_get_item.function_name,
    module.lambda_create_item.function_name,
    module.lambda_update_item.function_name,
    module.lambda_delete_item.function_name,
    module.lambda_stream_processor.function_name,
  ]
  api_gateway_id = module.api_gateway.rest_api_id
}
