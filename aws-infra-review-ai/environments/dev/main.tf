# =============================================================================
# dev 環境 - モジュール呼び出し定義
#
# 依存関係:
#   storage → agents（DynamoDB テーブル名が必要）
#   storage → api（S3 バケット名が必要）
#   agents  → workflow（Lambda ARN が必要）
#   api     → workflow（Step Functions ARN が必要）[Week 3: API から直接起動する場合]
# =============================================================================

# -----------------------------------------------------------------------------
# storage モジュール
# S3（入力・レポート保存）と DynamoDB（議論ログ）を作成
# -----------------------------------------------------------------------------
module "storage" {
  source = "../../modules/storage"

  project_name = var.project_name
  environment  = var.environment
}

# -----------------------------------------------------------------------------
# security-reviewer エージェント Lambda
# IAM 最小権限・暗号化・VPC エンドポイント等をレビュー
# -----------------------------------------------------------------------------
module "security_reviewer" {
  source = "../../modules/agents/security-reviewer"

  project_name       = var.project_name
  environment        = var.environment
  dynamodb_table_name = module.storage.review_table_name
  dynamodb_table_arn  = module.storage.review_table_arn
}

# -----------------------------------------------------------------------------
# cost-reviewer エージェント Lambda
# リソーススペック・NAT Gateway・Savings Plans 等をレビュー
# -----------------------------------------------------------------------------
module "cost_reviewer" {
  source = "../../modules/agents/cost-reviewer"

  project_name       = var.project_name
  environment        = var.environment
  dynamodb_table_name = module.storage.review_table_name
  dynamodb_table_arn  = module.storage.review_table_arn
}

# -----------------------------------------------------------------------------
# reliability-reviewer エージェント Lambda
# Single AZ・バックアップ・フェイルオーバー等をレビュー
# -----------------------------------------------------------------------------
module "reliability_reviewer" {
  source = "../../modules/agents/reliability-reviewer"

  project_name       = var.project_name
  environment        = var.environment
  dynamodb_table_name = module.storage.review_table_name
  dynamodb_table_arn  = module.storage.review_table_arn
}

# -----------------------------------------------------------------------------
# operations-reviewer エージェント Lambda
# タグ戦略・監視・ログ・デプロイ戦略等をレビュー
# -----------------------------------------------------------------------------
module "operations_reviewer" {
  source = "../../modules/agents/operations-reviewer"

  project_name       = var.project_name
  environment        = var.environment
  dynamodb_table_name = module.storage.review_table_name
  dynamodb_table_arn  = module.storage.review_table_arn
}

# -----------------------------------------------------------------------------
# api モジュール
# API Gateway REST API - レビュー投入口
# POST /reviews: セッション作成 + S3 署名付き URL 発行
# -----------------------------------------------------------------------------
module "api" {
  source = "../../modules/api"

  project_name        = var.project_name
  environment         = var.environment
  input_bucket_id     = module.storage.input_bucket_id
  input_bucket_arn    = module.storage.input_bucket_arn
  review_table_name   = module.storage.review_table_name
  review_table_arn    = module.storage.review_table_arn
}

# -----------------------------------------------------------------------------
# Chatwork API トークン - SSM Parameter Store（SecureString）に保管
# Lambda が実行時に取得する（環境変数へのハードコード禁止）
# chatwork_api_token が未設定の場合でもプランは通る（デフォルト値 ""）
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "chatwork_api_token" {
  name  = "/${var.project_name}/${var.environment}/chatwork/api_token"
  type  = "SecureString"
  value = var.chatwork_api_token == "" ? "PLACEHOLDER" : var.chatwork_api_token

  lifecycle {
    # terraform apply 後に手動で値を更新しても plan で diff が出ないよう無視
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# supervisor エージェント Lambda
# 4 エージェントの結果を統合・トレードオフ明示・優先アクション絞り込み
# -----------------------------------------------------------------------------
module "supervisor" {
  source = "../../modules/agents/supervisor"

  project_name        = var.project_name
  environment         = var.environment
  dynamodb_table_name = module.storage.review_table_name
  dynamodb_table_arn  = module.storage.review_table_arn
}

# -----------------------------------------------------------------------------
# workflow モジュール
# Step Functions ステートマシン + S3 トリガー（workflow-starter Lambda）
#
# S3 PUT → workflow-starter → Step Functions StartExecution
#   → Parallel（4 エージェント）→ supervisor → DynamoDB 更新（completed）
# -----------------------------------------------------------------------------
module "workflow" {
  source = "../../modules/workflow"

  project_name      = var.project_name
  environment       = var.environment
  input_bucket_id   = module.storage.input_bucket_id
  input_bucket_arn  = module.storage.input_bucket_arn
  review_table_name = module.storage.review_table_name
  review_table_arn  = module.storage.review_table_arn

  # 4 エージェント Lambda ARN（Step Functions が並列実行する）
  security_reviewer_arn    = module.security_reviewer.lambda_function_arn
  cost_reviewer_arn        = module.cost_reviewer.lambda_function_arn
  reliability_reviewer_arn = module.reliability_reviewer.lambda_function_arn
  operations_reviewer_arn  = module.operations_reviewer.lambda_function_arn

  # supervisor Lambda ARN（Parallel 完了後に統合処理を実行する）
  supervisor_arn = module.supervisor.lambda_function_arn

  # report-generator ARN（HTML レポート生成 + S3 保存）
  report_generator_arn = module.report_generator.lambda_function_arn

  # chatwork-notifier ARN（Chatwork 通知）
  chatwork_notifier_arn = module.chatwork_notifier.lambda_function_arn
}

# -----------------------------------------------------------------------------
# report-generator モジュール
# HTML レポートを生成して S3 に保存し、署名付き URL を返す
# -----------------------------------------------------------------------------
module "report_generator" {
  source = "../../modules/report-generator"

  project_name        = var.project_name
  environment         = var.environment
  dynamodb_table_name = module.storage.review_table_name
  dynamodb_table_arn  = module.storage.review_table_arn
  reports_bucket_id   = module.storage.reports_bucket_id
  reports_bucket_arn  = module.storage.reports_bucket_arn
}

# -----------------------------------------------------------------------------
# chatwork-notifier モジュール
# レビュー完了後に Chatwork ルームへサマリーとレポートリンクを通知する
# -----------------------------------------------------------------------------
module "chatwork_notifier" {
  source = "../../modules/chatwork-notifier"

  project_name            = var.project_name
  environment             = var.environment
  chatwork_room_id        = var.chatwork_room_id
  chatwork_token_ssm_path = aws_ssm_parameter.chatwork_api_token.name
}

# -----------------------------------------------------------------------------
# observability モジュール
# CloudWatch アラーム: SF 失敗・タイムアウト + Lambda エラー検知
# alarm_email を設定すると SNS Email サブスクリプションで通知が届く
# -----------------------------------------------------------------------------
module "observability" {
  source = "../../modules/observability"

  project_name                   = var.project_name
  environment                    = var.environment
  state_machine_name             = module.workflow.state_machine_name
  workflow_starter_function_name = module.workflow.workflow_starter_function_name
  supervisor_function_name       = module.supervisor.lambda_function_name
  alarm_email                    = var.alarm_email
}
