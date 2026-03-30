# terraform/environments/dev/main.tf
#
# dev 環境のルートモジュール。
# 各モジュールを組み合わせてサーバーレス API 基盤を構築する。
#
# アーキテクチャ:
#   API Gateway → Lambda → DynamoDB
#   DynamoDB Streams → stream-processor Lambda → S3 (監査ログ)

locals {
  # プロジェクト共通の命名プレフィックス
  # 例: sap-dev-create-item
  prefix = "${var.project}-${var.environment}"

  # Lambda 関数の共通設定
  # arm64 は x86_64 より約20% コスト削減。
  # Python 3.12 は Lambda のサポート対象の最新バージョン。
  lambda_runtime      = "python3.12"
  lambda_architecture = ["arm64"]

  # Lambda のタイムアウト設定。
  # API Gateway の統合タイムアウトは最大29秒。
  # Lambda のタイムアウトをこれより短く設定することで、
  # API GW 側でタイムアウトする前に Lambda がエラーを返せる。
  lambda_timeout = 25 # API GW 統合タイムアウト(29s) より短く設定
}

# ============================================================
# DynamoDB モジュール
# ============================================================
module "dynamodb" {
  source = "../../modules/dynamodb"

  prefix      = local.prefix
  environment = var.environment

  # dev 環境では PITR（ポイントインタイムリカバリ）は無効
  # コスト削減のため。prod では有効化する。
  enable_pitr = false

  # dev 環境では DAX（DynamoDB Accelerator）は使用しない
  # DAX は高コストのため prod のみで使用する。
  enable_dax = false
}

# ============================================================
# IAM モジュール（Lambda 実行ロール）
# ============================================================
module "iam" {
  source = "../../modules/iam"

  prefix      = local.prefix
  environment = var.environment
  account_id  = var.account_id

  dynamodb_table_arn = module.dynamodb.table_arn
  audit_bucket_arn   = module.storage.audit_bucket_arn
}

# ============================================================
# ストレージモジュール（S3 監査ログ）
# ============================================================
module "storage" {
  source = "../../modules/storage"

  prefix      = local.prefix
  environment = var.environment
  account_id  = var.account_id
}

# ============================================================
# Lambda 関数モジュール
# ============================================================
module "lambda_list_items" {
  source = "../../modules/lambda-function"

  function_name = "${local.prefix}-list-items"
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/list_items"

  environment_variables = {
    DYNAMODB_TABLE_NAME = module.dynamodb.table_name
    ENVIRONMENT         = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-list-items"
  }

  execution_role_arn = module.iam.lambda_role_arns["list-items"]
}

module "lambda_get_item" {
  source = "../../modules/lambda-function"

  function_name = "${local.prefix}-get-item"
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/get_item"

  environment_variables = {
    DYNAMODB_TABLE_NAME = module.dynamodb.table_name
    ENVIRONMENT         = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-get-item"
  }

  execution_role_arn = module.iam.lambda_role_arns["get-item"]
}

module "lambda_create_item" {
  source = "../../modules/lambda-function"

  function_name = "${local.prefix}-create-item"
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/create_item"

  environment_variables = {
    DYNAMODB_TABLE_NAME = module.dynamodb.table_name
    ENVIRONMENT         = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-create-item"
  }

  execution_role_arn = module.iam.lambda_role_arns["create-item"]
}

module "lambda_update_item" {
  source = "../../modules/lambda-function"

  function_name = "${local.prefix}-update-item"
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/update_item"

  environment_variables = {
    DYNAMODB_TABLE_NAME = module.dynamodb.table_name
    ENVIRONMENT         = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-update-item"
  }

  execution_role_arn = module.iam.lambda_role_arns["update-item"]
}

module "lambda_delete_item" {
  source = "../../modules/lambda-function"

  function_name = "${local.prefix}-delete-item"
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  timeout       = local.lambda_timeout
  source_dir    = "${path.root}/../../../src/delete_item"

  environment_variables = {
    DYNAMODB_TABLE_NAME = module.dynamodb.table_name
    ENVIRONMENT         = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-delete-item"
  }

  execution_role_arn = module.iam.lambda_role_arns["delete-item"]
}

module "lambda_stream_processor" {
  source = "../../modules/lambda-function"

  function_name = "${local.prefix}-stream-processor"
  handler       = "handler.handler"
  runtime       = local.lambda_runtime
  architectures = local.lambda_architecture
  # stream-processor は非同期処理のため API GW タイムアウト制約なし
  timeout    = 60
  source_dir = "${path.root}/../../../src/stream_processor"

  environment_variables = {
    AUDIT_BUCKET_NAME = module.storage.audit_bucket_name
    ENVIRONMENT       = var.environment
    POWERTOOLS_SERVICE_NAME = "${local.prefix}-stream-processor"
  }

  execution_role_arn = module.iam.lambda_role_arns["stream-processor"]

  # DynamoDB Streams からのイベントソースマッピング
  event_source_arn = module.dynamodb.stream_arn
}

# ============================================================
# API Gateway モジュール
# ============================================================
module "api_gateway" {
  source = "../../modules/api-gateway"

  prefix      = local.prefix
  environment = var.environment

  # dev 環境では WAF は使用しない（コスト削減）
  # prod では enable_waf = true にして allowed_ips を設定する
  enable_waf  = false
  allowed_ips = var.allowed_ips

  # Lambda 統合設定
  lambda_arns = {
    list_items   = module.lambda_list_items.function_arn
    get_item     = module.lambda_get_item.function_arn
    create_item  = module.lambda_create_item.function_arn
    update_item  = module.lambda_update_item.function_arn
    delete_item  = module.lambda_delete_item.function_arn
  }

  # dev 環境では Cognito 認証を無効化
  # 開発中の動作確認を容易にするため
  cognito_user_pool_arn = null
}

# ============================================================
# モニタリングモジュール
# ============================================================
module "monitoring" {
  source = "../../modules/monitoring"

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
