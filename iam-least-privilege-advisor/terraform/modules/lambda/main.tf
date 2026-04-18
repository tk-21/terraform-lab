data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------
# デプロイパッケージ: ソースディレクトリを zip 化
# Phase 3 で Lambda コードが配置されると自動的に参照される
# -----------------------------------------------------------------------
data "archive_file" "analyzer_trigger" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/analyzer_trigger"
  output_path = "${path.root}/../.terraform/lambda_zips/analyzer_trigger.zip"
}

data "archive_file" "policy_advisor" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/policy_advisor"
  output_path = "${path.root}/../.terraform/lambda_zips/policy_advisor.zip"
}

# -----------------------------------------------------------------------
# CloudWatch Logs グループ（Lambda より先に作成して保持期間を管理）
# -----------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "analyzer_trigger" {
  name              = "/aws/lambda/${var.project_name}-analyzer-trigger"
  retention_in_days = 30

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "policy_advisor" {
  name              = "/aws/lambda/${var.project_name}-policy-advisor"
  retention_in_days = 30

  tags = var.tags
}

# -----------------------------------------------------------------------
# analyzer-trigger Lambda
# 役割: Access Analyzer のスキャン実行・結果収集・S3 保存・policy-advisor 起動
# -----------------------------------------------------------------------
resource "aws_lambda_function" "analyzer_trigger" {
  function_name = "${var.project_name}-analyzer-trigger"
  description   = "Access Analyzer スキャン実行・結果収集・policy-advisor 非同期起動"
  role          = var.analyzer_trigger_role_arn

  filename         = data.archive_file.analyzer_trigger.output_path
  source_code_hash = data.archive_file.analyzer_trigger.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 60

  environment {
    variables = {
      S3_BUCKET_NAME              = var.results_bucket_name
      POLICY_ADVISOR_FUNCTION_NAME = "${var.project_name}-policy-advisor"
    }
  }

  depends_on = [aws_cloudwatch_log_group.analyzer_trigger]

  tags = var.tags
}

# -----------------------------------------------------------------------
# policy-advisor Lambda
# 役割: S3 から結果取得・Bedrock で最小権限ポリシー生成・GitHub PR 作成・Chatwork 通知
# -----------------------------------------------------------------------
resource "aws_lambda_function" "policy_advisor" {
  function_name = "${var.project_name}-policy-advisor"
  description   = "Bedrock による最小権限ポリシー生成・GitHub PR 作成・Chatwork 通知"
  role          = var.policy_advisor_role_arn

  filename         = data.archive_file.policy_advisor.output_path
  source_code_hash = data.archive_file.policy_advisor.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  memory_size      = 512
  timeout          = 120

  environment {
    variables = {
      S3_BUCKET_NAME          = var.results_bucket_name
      GITHUB_TOKEN_SECRET_ARN = var.github_token_secret_arn
      CHATWORK_SECRET_ARN     = var.chatwork_secret_arn
      CHATWORK_ROOM_ID        = var.chatwork_room_id
      GITHUB_OWNER            = var.github_owner
      GITHUB_REPO             = var.github_repo
      BEDROCK_MODEL_ID        = var.bedrock_model_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.policy_advisor]

  tags = var.tags
}

# -----------------------------------------------------------------------
# analyzer-trigger から policy-advisor を呼び出す権限
# （EventBridge Scheduler から analyzer-trigger が起動した後、
#   analyzer-trigger が policy-advisor を非同期呼び出しするため）
# -----------------------------------------------------------------------
resource "aws_lambda_permission" "allow_analyzer_trigger_invoke_advisor" {
  statement_id  = "AllowAnalyzerTriggerInvokeAdvisor"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.policy_advisor.function_name
  principal     = "lambda.amazonaws.com"
  source_arn    = aws_lambda_function.analyzer_trigger.arn
}
