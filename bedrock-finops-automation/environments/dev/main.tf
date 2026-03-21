# ============================================================
# bedrock-finops-automation - dev environment
# ============================================================
# モジュール呼び出し順序はCLAUDE.mdの依存関係に従う:
#   storage → collector → anomaly-detector
# ============================================================

module "storage" {
  source = "../../modules/storage"

  project_name = var.project_name
  environment  = var.environment
}

module "collector" {
  source = "../../modules/collector"

  project_name        = var.project_name
  environment         = var.environment
  report_bucket_name  = module.storage.report_bucket_name
  report_bucket_arn   = module.storage.report_bucket_arn
  dynamodb_table_name = module.storage.dynamodb_table_name
  dynamodb_table_arn  = module.storage.dynamodb_table_arn
}

module "anomaly_detector" {
  source = "../../modules/anomaly-detector"

  project_name        = var.project_name
  environment         = var.environment
  report_bucket_name  = module.storage.report_bucket_name
  report_bucket_arn   = module.storage.report_bucket_arn
  dynamodb_table_name = module.storage.dynamodb_table_name
  dynamodb_table_arn  = module.storage.dynamodb_table_arn
}

module "ai_reporter" {
  source = "../../modules/ai-reporter"

  project_name        = var.project_name
  environment         = var.environment
  report_bucket_name  = module.storage.report_bucket_name
  report_bucket_arn   = module.storage.report_bucket_arn
  dynamodb_table_name = module.storage.dynamodb_table_name
  dynamodb_table_arn  = module.storage.dynamodb_table_arn
}

module "html_formatter" {
  source = "../../modules/html-formatter"

  project_name        = var.project_name
  environment         = var.environment
  report_bucket_name  = module.storage.report_bucket_name
  report_bucket_arn   = module.storage.report_bucket_arn
  dynamodb_table_name = module.storage.dynamodb_table_name
  dynamodb_table_arn  = module.storage.dynamodb_table_arn
}

module "chatwork_notifier" {
  source = "../../modules/chatwork-notifier"

  project_name        = var.project_name
  environment         = var.environment
  report_bucket_name  = module.storage.report_bucket_name
  report_bucket_arn   = module.storage.report_bucket_arn
  dynamodb_table_name = module.storage.dynamodb_table_name
  dynamodb_table_arn  = module.storage.dynamodb_table_arn
}

module "workflow" {
  source = "../../modules/workflow"

  project_name                 = var.project_name
  environment                  = var.environment
  collector_lambda_arn         = module.collector.lambda_arn
  anomaly_detector_lambda_arn  = module.anomaly_detector.lambda_arn
  ai_reporter_lambda_arn       = module.ai_reporter.lambda_arn
  html_formatter_lambda_arn    = module.html_formatter.lambda_arn
  chatwork_notifier_lambda_arn = module.chatwork_notifier.lambda_arn
}

module "scheduler" {
  source = "../../modules/scheduler"

  project_name      = var.project_name
  environment       = var.environment
  state_machine_arn = module.workflow.state_machine_arn

  # dev 環境では誤発動防止のため無効化。手動テストが完了したら true に変更する
  enabled = false
}
