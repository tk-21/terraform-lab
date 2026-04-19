# Ansible Playbook AI Reviewer - メインTerraform設定
# IAMロール・SSMパラメータ・Lambda・API Gatewayを構築

terraform {
  required_version = ">= 1.9.0"

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

# 現在のAWSアカウント情報を取得
data "aws_caller_identity" "current" {}

# 共通タグ（全リソースに適用）
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "infra-team"
    CostCenter  = "portfolio"
  }
}

# ============================================================
# IAMロール: ansible-ai-reviewer-role
# ============================================================

# Lambda信頼ポリシー
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Lambda実行ロール
resource "aws_iam_role" "reviewer" {
  name               = "ansible-ai-reviewer-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = local.common_tags
}

# インラインポリシー: Bedrock・SSM・CloudWatch Logsへのアクセス
data "aws_iam_policy_document" "reviewer_policy" {
  # Bedrock: 特定モデル（Claude Sonnet 3.5）のみ呼び出し許可
  statement {
    sid    = "AllowBedrockInvokeModel"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
    ]
    resources = [
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0",
    ]
  }

  # SSM: /ansible-ai-reviewer/ プレフィックスのパラメータのみ取得許可
  statement {
    sid    = "AllowSSMGetParameter"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ansible-ai-reviewer/*",
    ]
  }

  # CloudWatch Logs: Lambda用ロググループへの書き込み許可
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/ansible-ai-reviewer:*",
    ]
  }
}

resource "aws_iam_role_policy" "reviewer" {
  name   = "ansible-ai-reviewer-policy"
  role   = aws_iam_role.reviewer.id
  policy = data.aws_iam_policy_document.reviewer_policy.json
}

# ============================================================
# SSMパラメータ
# ============================================================

# GitHub Token（SecureString）
resource "aws_ssm_parameter" "github_token" {
  name        = "/ansible-ai-reviewer/github-token"
  description = "GitHub API Token（PRコメント投稿用）"
  type        = "SecureString"
  value       = "PLACEHOLDER"

  # 初回作成後はTerraform管理外で値を更新するため、差分を無視
  lifecycle {
    ignore_changes = [value]
  }

  tags = local.common_tags
}

# 追加の認証シークレット（API Gateway経由のリクエスト検証用）
resource "aws_ssm_parameter" "api_key_secret" {
  name        = "/ansible-ai-reviewer/api-key-secret"
  description = "API Gatewayリクエストの追加認証シークレット"
  type        = "SecureString"
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }

  tags = local.common_tags
}

# ============================================================
# モジュール: Lambda
# ============================================================

module "reviewer_lambda" {
  source = "./modules/reviewer_lambda"

  function_name         = "ansible-ai-reviewer"
  role_arn              = aws_iam_role.reviewer.arn
  timeout               = var.lambda_timeout
  memory                = var.lambda_memory
  github_token_ssm_path = var.github_token_ssm_path
  bedrock_region        = var.bedrock_region
  environment           = var.environment
  tags                  = local.common_tags
}

# ============================================================
# モジュール: API Gateway
# ============================================================

module "api_gateway" {
  source = "./modules/api_gateway"

  api_name             = "ansible-ai-reviewer-api"
  stage_name           = var.api_gateway_stage
  lambda_invoke_arn    = module.reviewer_lambda.lambda_invoke_arn
  lambda_function_name = module.reviewer_lambda.lambda_function_name
  aws_region           = var.aws_region
  environment          = var.environment
  tags                 = local.common_tags
}

# ============================================================
# SSMパラメータ: API GatewayのAPIキー値を保存
# APIキー値はAWS管理のため、data sourceで取得してSSMに格納
# ============================================================

data "aws_api_gateway_api_key" "reviewer" {
  id = module.api_gateway.api_key_id

  depends_on = [module.api_gateway]
}

resource "aws_ssm_parameter" "api_gateway_key" {
  name        = "/ansible-ai-reviewer/api-gateway-key"
  description = "API GatewayのAPIキー値（GitHub Actionsで使用）"
  type        = "SecureString"
  value       = data.aws_api_gateway_api_key.reviewer.value

  tags = local.common_tags
}
