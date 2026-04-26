# =============================================================================
# IaC Drift Detective - メインリソース定義
# ドリフト検知・Bedrock分析・GitHub PR自動作成システムのインフラ
# =============================================================================

# AWSアカウントIDを動的取得（ハードコードを避けるため）
data "aws_caller_identity" "current" {}

# 現在のリージョンを取得
data "aws_region" "current" {}

# 全リソースに共通で適用するタグ
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "infra-team"
    CostCenter  = "portfolio"
  }
}

# =============================================================================
# 1. S3バケット（ドリフト検知レポート保存用）
# =============================================================================

# ドリフト検知レポートを保存するS3バケット
resource "aws_s3_bucket" "reports" {
  bucket = "drift-detective-reports-${data.aws_caller_identity.current.account_id}"
  tags   = merge(local.common_tags, { Name = "drift-detective-reports" })
}

# バージョニング有効化（レポートの履歴管理・誤削除防止）
resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

# パブリックアクセスを全てブロック（セキュリティ強化）
resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ライフサイクル設定（コスト最適化）
resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "transition-to-glacier"
    status = "Enabled"

    filter {
      prefix = ""
    }

    # 90日後にGlacierへ移行してストレージコストを削減
    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    # 365日後に削除（長期保存不要なレポートを自動削除）
    expiration {
      days = 365
    }
  }
}

# =============================================================================
# 2. IAMロール: drift-detective-detector-role（ドリフト検知Lambda用）
# =============================================================================

# ドリフト検知Lambda用IAMロール
resource "aws_iam_role" "detector" {
  name = "drift-detective-detector-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# ドリフト検知Lambdaのインラインポリシー（最小権限の原則に従い必要な操作のみ許可）
resource "aws_iam_role_policy" "detector" {
  name = "drift-detective-detector-policy"
  role = aws_iam_role.detector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 監視対象のtfstateファイルのみ読み取り可能（他バケットへのアクセスを防止）
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.monitored_tfstate_bucket}/${var.monitored_tfstate_key}"
      },
      {
        # AWS ConfigはリソースARN指定不可のため例外的に*を使用
        Effect = "Allow"
        Action = [
          "config:DescribeConfigurationRecorders",
          "config:GetResourceConfigHistory"
        ]
        Resource = "*"
      },
      {
        # CloudFormationドリフト検知（対象アカウントのスタックリソースに限定）
        Effect = "Allow"
        Action = [
          "cloudformation:DetectStackDrift",
          "cloudformation:DescribeStackDriftDetectionStatus"
        ]
        Resource = "arn:aws:cloudformation:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stack/*/*"
      },
      {
        # CloudWatch Logsへの書き込み（Lambda実行ログ）
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# =============================================================================
# 3. IAMロール: drift-detective-analyzer-role（Bedrock分析Lambda用）
# =============================================================================

# Bedrock分析Lambda用IAMロール
resource "aws_iam_role" "analyzer" {
  name = "drift-detective-analyzer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# Bedrock分析Lambdaのインラインポリシー（最小権限）
resource "aws_iam_role_policy" "analyzer" {
  name = "drift-detective-analyzer-policy"
  role = aws_iam_role.analyzer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Claude Sonnet 3.5モデルの呼び出しのみ許可（他モデルへのアクセスを防止）
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0"
      },
      {
        # 分析レポートをS3に書き込み（レポートバケットのみ）
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${aws_s3_bucket.reports.id}/*"
      },
      {
        # CloudWatch Logsへの書き込み（Lambda実行ログ）
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# =============================================================================
# 4. IAMロール: drift-detective-pr-creator-role（GitHub PR作成Lambda用）
# =============================================================================

# GitHub PR作成Lambda用IAMロール
resource "aws_iam_role" "pr_creator" {
  name = "drift-detective-pr-creator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# PR作成Lambdaのインラインポリシー（最小権限）
resource "aws_iam_role_policy" "pr_creator" {
  name = "drift-detective-pr-creator-policy"
  role = aws_iam_role.pr_creator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # drift-detective配下のSSMパラメータのみ取得可能（GitHub Token・Chatwork Token等）
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/drift-detective/*"
      },
      {
        # 分析レポートをS3から読み取り（PR本文生成のため）
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${aws_s3_bucket.reports.id}/*"
      },
      {
        # CloudWatch Logsへの書き込み（Lambda実行ログ）
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# =============================================================================
# 5. IAMロール: drift-detective-sfn-role（Step Functions用）
# =============================================================================

# Step Functions用IAMロール（Lambdaオーケストレーション）
resource "aws_iam_role" "sfn" {
  name = "drift-detective-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# Step FunctionsのインラインポリシーLambda呼び出し・ログ出力権限）
resource "aws_iam_role_policy" "sfn" {
  name = "drift-detective-sfn-policy"
  role = aws_iam_role.sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ドリフト検知ワークフローの3つのLambdaのみ呼び出し可能
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:drift-detective-detector",
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:drift-detective-analyzer",
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:drift-detective-pr-creator"
        ]
      },
      {
        # Step FunctionsのログをCloudWatch Logsに出力するための権限
        # ログ配信設定はリソースARN指定不可のため*を使用
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

# =============================================================================
# 6. EventBridge Rule（日次スケジュール実行）
# =============================================================================

# 日次スケジュール実行ルール（毎日09:00 JST = 00:00 UTC）
resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "drift-detective-schedule"
  schedule_expression = "cron(0 0 * * ? *)"
  description         = "ドリフト検知ワークフローの日次スケジュール実行"

  tags = local.common_tags
}

# EventBridgeからStep Functionsを起動するターゲット設定
resource "aws_cloudwatch_event_target" "sfn" {
  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "DriftDetectionWorkflow"
  arn       = module.step_functions.state_machine_arn
  role_arn  = aws_iam_role.sfn.arn
}

# =============================================================================
# 7. SSMパラメータ（SecureString: 機密情報の安全な保管）
# =============================================================================

# GitHub APIトークン（SecureStringで暗号化保管）
# 初期値はPLACEHOLDER。デプロイ後に手動で実際のトークンに更新すること
resource "aws_ssm_parameter" "github_token" {
  name        = "/drift-detective/github-token"
  type        = "SecureString"
  value       = "PLACEHOLDER"
  description = "GitHub APIトークン（Secrets設定後に手動で更新すること）"

  tags = local.common_tags

  lifecycle {
    # Terraform外で更新された実際のトークン値を上書きしない
    ignore_changes = [value]
  }
}

# Chatwork APIトークン（SecureStringで暗号化保管）
# 初期値はPLACEHOLDER。デプロイ後に手動で実際のトークンに更新すること
resource "aws_ssm_parameter" "chatwork_api_token" {
  name        = "/drift-detective/chatwork-api-token"
  type        = "SecureString"
  value       = "PLACEHOLDER"
  description = "Chatwork APIトークン（Secrets設定後に手動で更新すること）"

  tags = local.common_tags

  lifecycle {
    # Terraform外で更新された実際のトークン値を上書きしない
    ignore_changes = [value]
  }
}

# =============================================================================
# 8. CloudWatch Logs グループ（Lambda・Step Functions用）
# =============================================================================

# ドリフト検知LambdaのCloudWatch Logsグループ
resource "aws_cloudwatch_log_group" "detector" {
  name              = "/aws/lambda/drift-detective-detector"
  retention_in_days = 30

  tags = local.common_tags
}

# Bedrock分析LambdaのCloudWatch Logsグループ
resource "aws_cloudwatch_log_group" "analyzer" {
  name              = "/aws/lambda/drift-detective-analyzer"
  retention_in_days = 30

  tags = local.common_tags
}

# PR作成LambdaのCloudWatch Logsグループ
resource "aws_cloudwatch_log_group" "pr_creator" {
  name              = "/aws/lambda/drift-detective-pr-creator"
  retention_in_days = 30

  tags = local.common_tags
}

# Step FunctionsのCloudWatch Logsグループ
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/DriftDetectionWorkflow"
  retention_in_days = 30

  tags = local.common_tags
}

# =============================================================================
# 9. Lambda モジュール（Phase 2-3 追記）
# =============================================================================

module "drift_detector" {
  source = "./modules/drift_detector"

  environment              = var.environment
  lambda_role_arn          = aws_iam_role.detector.arn
  monitored_tfstate_bucket = var.monitored_tfstate_bucket
  monitored_tfstate_key    = var.monitored_tfstate_key
  log_group_name           = aws_cloudwatch_log_group.detector.name
  tags                     = local.common_tags
}

module "bedrock_analyzer" {
  source = "./modules/bedrock_analyzer"

  environment     = var.environment
  lambda_role_arn = aws_iam_role.analyzer.arn
  reports_bucket  = aws_s3_bucket.reports.id
  bedrock_region  = var.bedrock_region
  log_group_name  = aws_cloudwatch_log_group.analyzer.name
  tags            = local.common_tags
}

module "pr_creator" {
  source = "./modules/pr_creator"

  environment      = var.environment
  lambda_role_arn  = aws_iam_role.pr_creator.arn
  github_owner     = var.github_owner
  github_repo      = var.github_repo
  chatwork_room_id = var.chatwork_room_id
  log_group_name   = aws_cloudwatch_log_group.pr_creator.name
  tags             = local.common_tags
}

# =============================================================================
# 10. Step Functions モジュール（Phase 3 追記）
# =============================================================================

module "step_functions" {
  source = "./modules/step_functions"

  environment                   = var.environment
  sfn_role_arn                  = aws_iam_role.sfn.arn
  drift_detector_function_arn   = module.drift_detector.function_arn
  bedrock_analyzer_function_arn = module.bedrock_analyzer.function_arn
  pr_creator_function_arn       = module.pr_creator.function_arn
  log_group_arn                 = aws_cloudwatch_log_group.sfn.arn
  tags                          = local.common_tags
}
